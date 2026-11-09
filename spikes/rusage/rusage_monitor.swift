import Foundation
import Darwin

struct ProcStat {
    var name: String
    var path: String
    var uid: uid_t
    var ruid: uid_t
    var bytesRead: UInt64
    var bytesWritten: UInt64
    var rusageErrno: Int32
}

func getKinfoProc(pid: pid_t) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let ret = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    if ret == 0 && size > 0 {
        return info
    }
    return nil
}

func getProcessNameAndPath(pid: pid_t) -> (String, String, uid_t, uid_t) {
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    let path = pathLen > 0 ? String(cString: pathBuffer) : ""

    var name = ""
    var uid: uid_t = 0
    var ruid: uid_t = 0
    if let kp = getKinfoProc(pid: pid) {
        uid = kp.kp_eproc.e_ucred.cr_uid
        ruid = kp.kp_eproc.e_pcred.p_ruid
        var comm = kp.kp_proc.p_comm
        name = withUnsafePointer(to: &comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0)
            }
        }
    }
    if !path.isEmpty {
        let base = (path as NSString).lastPathComponent
        if !base.isEmpty {
            name = base
        }
    }
    return (name, path, uid, ruid)
}

func getRusageV4(pid: pid_t) -> (rusage_info_v4?, Int32) {
    errno = 0
    var info = rusage_info_v4()
    let res = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
            return proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
        }
    }
    if res == 0 {
        return (info, 0)
    }
    return (nil, errno)
}

func listAllPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let actualCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
    guard actualCount > 0 else { return [] }
    return Array(pids.prefix(Int(actualCount))).filter { $0 > 0 }
}

func formatBytes(_ bytes: Double) -> String {
    if bytes >= 1_000_000_000 {
        return String(format: "%.2f GB", bytes / 1_000_000_000)
    } else if bytes >= 1_000_000 {
        return String(format: "%.2f MB", bytes / 1_000_000)
    } else if bytes >= 1_000 {
        return String(format: "%.1f KB", bytes / 1_000)
    } else {
        return String(format: "%.0f B", bytes)
    }
}

func isTargetProcess(name: String, path: String) -> Bool {
    let targets = ["Finder", "DesktopServicesHelper", "DesktopServicesScriptingHelper", "fileproviderd"]
    for t in targets {
        if name == t || name.contains("DesktopServices") || path.contains(t) {
            return true
        }
    }
    return false
}

print("Starting rusage_monitor (sampling every 250ms)...")
print("Current UID: \(getuid()), EUID: \(geteuid()) (non-root: \(geteuid() != 0))")
fflush(stdout)

var previousStats: [pid_t: ProcStat] = [:]
var totalObservedRead: [String: UInt64] = [:]
var totalObservedWrite: [String: UInt64] = [:]
var reportedPermErrors: Set<String> = []
var lastSampleTime = DispatchTime.now()

for pid in listAllPids() {
    let (name, path, uid, ruid) = getProcessNameAndPath(pid: pid)
    let (ru, err) = getRusageV4(pid: pid)
    if let ru = ru {
        previousStats[pid] = ProcStat(
            name: name, path: path, uid: uid, ruid: ruid,
            bytesRead: ru.ri_diskio_bytesread,
            bytesWritten: ru.ri_diskio_byteswritten,
            rusageErrno: 0
        )
    } else if isTargetProcess(name: name, path: path) {
        previousStats[pid] = ProcStat(
            name: name, path: path, uid: uid, ruid: ruid,
            bytesRead: 0, bytesWritten: 0, rusageErrno: err
        )
    }
}

let durationSeconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 10.0) : 10.0
let startTime = Date()

while Date().timeIntervalSince(startTime) < durationSeconds {
    usleep(250_000) // 250ms
    let now = DispatchTime.now()
    let dt = Double(now.uptimeNanoseconds - lastSampleTime.uptimeNanoseconds) / 1_000_000_000.0
    lastSampleTime = now
    let elapsed = Date().timeIntervalSince(startTime)

    var currentStats: [pid_t: ProcStat] = [:]
    let pids = listAllPids()
    var lineParts: [String] = []

    for pid in pids {
        let prev = previousStats[pid]
        let (name, path, uid, ruid) = prev.map { ($0.name, $0.path, $0.uid, $0.ruid) } ?? getProcessNameAndPath(pid: pid)
        let target = isTargetProcess(name: name, path: path)
        let (ru, err) = getRusageV4(pid: pid)

        if let ru = ru {
            currentStats[pid] = ProcStat(
                name: name, path: path, uid: uid, ruid: ruid,
                bytesRead: ru.ri_diskio_bytesread,
                bytesWritten: ru.ri_diskio_byteswritten,
                rusageErrno: 0
            )
            let prevRead = prev?.bytesRead ?? ru.ri_diskio_bytesread
            let prevWrite = prev?.bytesWritten ?? ru.ri_diskio_byteswritten
            let baseRead = (prev == nil) ? 0 : prevRead
            let baseWrite = (prev == nil) ? 0 : prevWrite
            let dRead = ru.ri_diskio_bytesread >= baseRead ? (ru.ri_diskio_bytesread - baseRead) : 0
            let dWrite = ru.ri_diskio_byteswritten >= baseWrite ? (ru.ri_diskio_byteswritten - baseWrite) : 0

            if dRead > 0 || dWrite > 0 {
                let key = "\(name)[\(pid)] (uid=\(uid))"
                totalObservedRead[key, default: 0] += dRead
                totalObservedWrite[key, default: 0] += dWrite
            }

            let hasSignificantIO = (dRead + dWrite) > 100_000 // > 100 KB in 250ms
            if target || hasSignificantIO {
                let rRate = Double(dRead) / dt
                let wRate = Double(dWrite) / dt
                lineParts.append(String(format: "%@[%d,uid=%d]: R=%@/s W=%@/s", name, pid, uid, formatBytes(rRate), formatBytes(wRate)))
            }
        } else if target {
            currentStats[pid] = ProcStat(
                name: name, path: path, uid: uid, ruid: ruid,
                bytesRead: 0, bytesWritten: 0, rusageErrno: err
            )
            let errStr = String(cString: strerror(err))
            let permKey = "\(name)[\(pid)]"
            if !reportedPermErrors.contains(permKey) {
                reportedPermErrors.insert(permKey)
                print("  [!] Target process \(name) (pid=\(pid), uid=\(uid), ruid=\(ruid), path=\(path)): proc_pid_rusage failed with errno=\(err) (\(errStr))")
            }
            lineParts.append(String(format: "%@[%d,uid=%d]: RUSAGE_ERR(%d:%@)", name, pid, uid, err, errStr))
        }
    }

    previousStats = currentStats
    print(String(format: "[%5.2fs] %@", elapsed, lineParts.joined(separator: " | ")))
    fflush(stdout)
}

print("\n=== Cumulative I/O during monitoring window ===")
for key in Set(totalObservedRead.keys).union(totalObservedWrite.keys).sorted() {
    let r = totalObservedRead[key] ?? 0
    let w = totalObservedWrite[key] ?? 0
    if r > 1_000_000 || w > 1_000_000 || key.contains("Finder") || key.contains("DesktopServices") {
        print(String(format: "  %@ -> Read: %@ (%llu B), Written: %@ (%llu B)", key, formatBytes(Double(r)), r, formatBytes(Double(w)), w))
    }
}
fflush(stdout)
