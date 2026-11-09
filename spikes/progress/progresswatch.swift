// progresswatch: Spike A (athena)
// Subscribes to NSProgress published for file URLs (e.g. by Finder) and logs
// what we can see: counts, throughput, kind, fileOperationKind, userInfo.
//
// Build:  swiftc -O -swift-version 5 progresswatch.swift -o progresswatch
// Usage:  ./progresswatch [--truth <path>] [--duration <sec>] [--quiet] <path> [<path> ...]
//   Each <path> gets its own Progress.addSubscriber(forFileURL:) subscription.
//   --truth <path>: also measure the real on-disk size of this file or folder
//                   (recursive sum of st_size) for lag comparison.
//   --quiet: shorter TICK lines (no full userInfo dump).
//
// Findings encoded here (macOS 27.0.1, Finder copy):
//   completedUnitCount/totalUnitCount are per-mille (0...1000), NOT bytes.
//   Bytes live in userInfo["NSProgressByteCompletedCountKey"/"NSProgressByteTotalCountKey"].
//   throughput is nil, so the rate must be derived from the byte counter.

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let t0 = Date()
func now() -> Double { Date().timeIntervalSince(t0) }
func log(_ s: String) { print("[\(String(format: "%8.3f", now()))] \(s)") }

var args = Array(CommandLine.arguments.dropFirst())
var truthPath: String? = nil
var duration: Double = 120
var quiet = false
var paths: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--truth": truthPath = args.removeFirst()
    case "--duration": duration = Double(args.removeFirst()) ?? 120
    case "--quiet": quiet = true
    default: paths.append(a)
    }
}
if paths.isEmpty { paths = ["/Volumes/FinderSpeedTest/athena"] }

let kBytesDone = ProgressUserInfoKey("NSProgressByteCompletedCountKey")
let kBytesTotal = ProgressUserInfoKey("NSProgressByteTotalCountKey")

func int64(_ v: Any?) -> Int64? {
    if let n = v as? NSNumber { return n.int64Value }
    return nil
}

final class Tracked {
    let id: Int
    let sub: String
    let progress: Progress
    let seenAt: Double
    var obs: NSKeyValueObservation?
    var kvoCount = 0
    // byte-counter change detection (polled at 10 ms)
    var lastBytes: Int64 = -2
    var lastBytesChangeAt: Double? = nil
    var byteChangeIntervals: [Double] = []
    var lagSamples: [Double] = []   // truth - reported, in bytes, sampled at each change
    var firstRealBytesAt: Double? = nil
    // tick-level rate
    var tickBytes: Int64 = 0
    var tickAt: Double
    var finished = false
    init(id: Int, sub: String, progress: Progress) {
        self.id = id; self.sub = sub; self.progress = progress
        self.seenAt = now(); self.tickAt = now()
    }
    var bytes: Int64 { int64(progress.userInfo[kBytesDone]) ?? -1 }
    var bytesTotal: Int64 { int64(progress.userInfo[kBytesTotal]) ?? -1 }
}

let lock = NSLock()
var tracked: [Tracked] = []
var nextID = 1

func describe(_ p: Progress, full: Bool = true) -> String {
    var s = "completed=\(p.completedUnitCount) total=\(p.totalUnitCount) "
        + "frac=\(String(format: "%.4f", p.fractionCompleted)) "
        + "throughput=\(p.throughput.map { String($0) } ?? "nil") "
        + "eta=\(p.estimatedTimeRemaining.map { String(format: "%.1f", $0) } ?? "nil") "
        + "kind=\(p.kind?.rawValue ?? "nil") "
        + "fileOpKind=\(p.fileOperationKind?.rawValue ?? "nil") "
        + "fileURL=\(p.fileURL?.path ?? "nil") "
        + "files=\(p.fileCompletedCount.map { String($0) } ?? "nil")/\(p.fileTotalCount.map { String($0) } ?? "nil") "
        + "bytes=\(int64(p.userInfo[kBytesDone]).map { String($0) } ?? "nil")/\(int64(p.userInfo[kBytesTotal]).map { String($0) } ?? "nil")"
    if full {
        let ui = p.userInfo.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ", ")
        s += " cancelled=\(p.isCancelled) paused=\(p.isPaused) indeterminate=\(p.isIndeterminate) userInfo={\(ui)}"
    }
    return s
}

func diskSize(_ path: String) -> Int64? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    if (st.st_mode & S_IFMT) != S_IFDIR { return Int64(st.st_size) }
    var total: Int64 = 0
    if let e = FileManager.default.enumerator(atPath: path) {
        for case let rel as String in e {
            var s2 = stat()
            if lstat(path + "/" + rel, &s2) == 0, (s2.st_mode & S_IFMT) == S_IFREG { total += Int64(s2.st_size) }
        }
    }
    return total
}

func stats(_ xs: [Double]) -> String {
    guard !xs.isEmpty else { return "n=0" }
    let s = xs.sorted()
    let mean = s.reduce(0, +) / Double(s.count)
    return "n=\(s.count) min=\(String(format: "%.3f", s.first!)) median=\(String(format: "%.3f", s[s.count / 2])) "
        + "mean=\(String(format: "%.3f", mean)) max=\(String(format: "%.3f", s.last!))"
}

var subscribers: [Any] = []
for path in paths {
    let url = URL(fileURLWithPath: path)
    let sub = Progress.addSubscriber(forFileURL: url) { progress in
        lock.lock()
        let t = Tracked(id: nextID, sub: path, progress: progress)
        nextID += 1
        tracked.append(t)
        lock.unlock()
        log("PUBLISHED #\(t.id) via sub=\(path) thread=\(Thread.isMainThread ? "main" : "bg") :: \(describe(progress))")
        t.obs = progress.observe(\.completedUnitCount, options: [.new]) { _, _ in
            lock.lock(); t.kvoCount += 1; lock.unlock()
        }
        return {
            lock.lock(); t.finished = true; lock.unlock()
            let dur = now() - t.seenAt
            let avg = Double(t.bytesTotal) / max(dur, 0.001) / 1_048_576
            log("UNPUBLISHED #\(t.id) (sub=\(t.sub)) alive=\(String(format: "%.3f", dur))s "
                + "kvoCompletedUnitCountChanges=\(t.kvoCount) avgOverLifetime=\(String(format: "%.1f", avg))MiB/s")
            log("  #\(t.id) byte-counter update interval (s): \(stats(t.byteChangeIntervals))")
            log("  #\(t.id) truth-minus-reported lag at each update (MiB): \(stats(t.lagSamples.map { $0 / 1_048_576 }))")
            log("  #\(t.id) final :: \(describe(t.progress))")
        }
    }
    subscribers.append(sub)
    log("subscribed to \(path)")
}

// Fast poll: detect each change of the byte counter (true update cadence).
let fast = Timer(timeInterval: 0.01, repeats: true) { _ in
    lock.lock(); let active = tracked.filter { !$0.finished }; lock.unlock()
    for t in active {
        let b = t.bytes
        if b != t.lastBytes {
            let n = now()
            if let l = t.lastBytesChangeAt, t.lastBytes >= 0 { t.byteChangeIntervals.append(n - l) }
            if b > 0, t.firstRealBytesAt == nil { t.firstRealBytesAt = n }
            var lagStr = ""
            if let tp = truthPath, let real = diskSize(tp), b >= 0 {
                t.lagSamples.append(Double(real - b))
                lagStr = " truth=\(real) lag=\(String(format: "%.1f", Double(real - b) / 1_048_576))MiB"
            }
            log("BYTES #\(t.id) \(t.lastBytes) -> \(b)\(lagStr) files=\(t.progress.fileCompletedCount ?? -1)/\(t.progress.fileTotalCount ?? -1) fileURL=\(t.progress.fileURL?.lastPathComponent ?? "nil")")
            t.lastBytes = b; t.lastBytesChangeAt = n
        }
    }
}
RunLoop.main.add(fast, forMode: .common)

// 250 ms tick: the "UI-rate" log the brief asked for.
let tick = Timer(timeInterval: 0.25, repeats: true) { _ in
    lock.lock(); let active = tracked.filter { !$0.finished }; lock.unlock()
    for t in active {
        let n = now(), b = t.bytes
        let rate = (n > t.tickAt && b >= 0 && t.tickBytes >= 0) ? Double(b - t.tickBytes) / (n - t.tickAt) : 0
        t.tickBytes = max(b, 0); t.tickAt = n
        log("TICK #\(t.id) derivedRate=\(String(format: "%.1f", rate / 1_048_576))MiB/s kvoSoFar=\(t.kvoCount) :: \(describe(t.progress, full: !quiet))")
    }
}
RunLoop.main.add(tick, forMode: .common)

DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
    log("duration reached, exiting")
    for s in subscribers { Progress.removeSubscriber(s) }
    exit(0)
}
signal(SIGTERM) { _ in exit(0) }
log("running for \(duration)s; pid=\(getpid()) epoch=\(String(format: "%.3f", t0.timeIntervalSince1970))")
RunLoop.main.run()
