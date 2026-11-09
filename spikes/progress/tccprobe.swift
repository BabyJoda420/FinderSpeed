// tccprobe: Spike A follow-up (athena). Does subscribing to TCC-protected folders need permission?
//
//   tccprobe pub <seconds> <file> [<file> ...]
//       Publishes a Finder-shaped NSProgress for each file URL (the files need not exist;
//       nothing is written to disk) and advances its byte counter every 0.5 s.
//   tccprobe sub <logfile> <seconds> <folder> [<folder> ...]
//       Subscribes to each folder and logs which progresses it receives, plus its ppid and
//       responsible pid (to prove it is not running under the terminal's TCC identity).
//
// Build: swiftc -O -swift-version 5 tccprobe.swift -o tccprobe   (then wrap it in TCCProbe.app)

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { print("usage: see header"); exit(2) }
args.removeFirst()

let t0 = Date()
var out: FileHandle? = nil
func log(_ s: String) {
    let line = String(format: "[%7.3f] ", Date().timeIntervalSince(t0)) + s + "\n"
    if let out { out.write(line.data(using: .utf8)!) } else { print(line, terminator: "") }
}

func responsiblePID(_ pid: pid_t) -> pid_t {
    typealias Fn = @convention(c) (pid_t) -> pid_t
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    else { return -1 }
    return unsafeBitCast(sym, to: Fn.self)(pid)
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "?"
}

let kDone = ProgressUserInfoKey("NSProgressByteCompletedCountKey")
let kTotal = ProgressUserInfoKey("NSProgressByteTotalCountKey")

switch mode {
case "pub":
    let secs = Double(args.removeFirst()) ?? 20
    var ps: [Progress] = []
    for path in args {
        let p = Progress(totalUnitCount: 1000)
        p.kind = .file
        p.fileOperationKind = .copying
        p.fileURL = URL(fileURLWithPath: path)
        p.setUserInfoObject(NSNumber(value: Int64(0)), forKey: kDone)
        p.setUserInfoObject(NSNumber(value: Int64(1_000_000_000)), forKey: kTotal)
        p.publish()
        ps.append(p)
        log("published \(path)")
    }
    var n: Int64 = 0
    let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
        n += 1
        for p in ps { p.setUserInfoObject(NSNumber(value: n * 10_000_000), forKey: kDone); p.completedUnitCount = n * 10 }
    }
    RunLoop.main.add(timer, forMode: .common)
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
        ps.forEach { $0.unpublish() }
        log("unpublished all, exiting")
        exit(0)
    }
    RunLoop.main.run()

case "sub":
    let logPath = args.removeFirst()
    FileManager.default.createFile(atPath: logPath, contents: nil)
    out = FileHandle(forWritingAtPath: logPath)
    let secs = Double(args.removeFirst()) ?? 15
    let me = getpid(), rp = responsiblePID(me)
    log("pid=\(me) ppid=\(getppid()) (\(procName(getppid()))) responsible=\(rp) (\(procName(rp))) "
        + "bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
    var subs: [Any] = []
    var seen: [String: Progress] = [:]
    for folder in args {
        subs.append(Progress.addSubscriber(forFileURL: URL(fileURLWithPath: folder, isDirectory: true)) { p in
            let path = p.fileURL?.path ?? "(fileURL nil)"
            seen[folder] = p
            log("RECEIVED via \(folder): \(path) bytes=\((p.userInfo[kDone] as? NSNumber)?.int64Value ?? -1)")
            return { log("unpublished \(path)") }
        })
        log("subscribed \(folder)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
        for (folder, p) in seen.sorted(by: { $0.key < $1.key }) {
            log("SUMMARY via \(folder) lastBytes=\((p.userInfo[kDone] as? NSNumber)?.int64Value ?? -1)")
        }
        log("SUMMARY received \(seen.count) of \(args.count) folders; exiting")
        subs.forEach { Progress.removeSubscriber($0) }
        exit(0)
    }
    RunLoop.main.run()

default:
    print("unknown mode \(mode)"); exit(2)
}
