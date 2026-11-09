// Engine/EngineDebug.swift (owner: athena)
//
// Headless debug mode: `FinderSpeed --engine-debug [extra folder ...] [--unwatch-after SECONDS]`
// Prints the current transfers once per second. Any non-flag arguments after --engine-debug
// are added with watch(folder:), e.g. `--engine-debug /Volumes/FinderSpeedTest/athena`.
//
// Called from App/main.swift:
//     if EngineDebug.isRequested() { EngineDebug.run() }

import Foundation

public enum EngineDebug {
    public static let flag = "--engine-debug"

    public static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(flag)
    }

    /// Starts a TransferMonitor and prints its transfers every second. Never returns (Ctrl-C to quit).
    /// Must be called on the main thread (e.g. top-level code in main.swift).
    public static func run(arguments: [String] = CommandLine.arguments) -> Never {
        MainActor.assumeIsolated { runOnMain(arguments: arguments) }
    }

    @MainActor
    private static func runOnMain(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let monitor = TransferMonitor()
        monitor.start()
        var extra: [URL] = []
        var unwatchAfter: TimeInterval? = nil
        if let i = arguments.firstIndex(of: flag) {
            var rest = Array(arguments[(i + 1)...])
            while !rest.isEmpty {
                let a = rest.removeFirst()
                if a == "--unwatch-after", let v = rest.first.flatMap(Double.init) {
                    rest.removeFirst(); unwatchAfter = v           // test hook: unwatch the extra folders mid-copy
                } else if !a.hasPrefix("-") {
                    extra.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
                }
            }
        }
        for f in extra { monitor.watch(folder: f) }
        if let delay = unwatchAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    print("engine-debug: unwatching \(extra.map(\.path))")
                    for f in extra { monitor.unwatch(folder: f) }
                }
            }
        }
        print("engine-debug: watching \(monitor.watchedFolders.count) folders:")
        for f in monitor.watchedFolders { print("  \(f.path)") }

        let t0 = Date()
        var idleTicks = 0
        var dumped: Set<UUID> = []
        var watched = Set(monitor.watchedFolders.map(\.path))
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let ts = String(format: "[%7.1fs]", Date().timeIntervalSince(t0))
                let nowWatched = Set(monitor.watchedFolders.map(\.path))
                for p in nowWatched.subtracting(watched).sorted() { print("\(ts) + watching \(p)") }
                for p in watched.subtracting(nowWatched).sorted() { print("\(ts) - unwatched \(p)") }
                watched = nowWatched
                let list = monitor.transfers
                if list.isEmpty {
                    idleTicks += 1
                    if idleTicks % 10 == 1 { print("\(ts) idle") }
                    return
                }
                idleTicks = 0
                for t in list {
                    print("\(ts) \(describe(t))")
                    if t.isFinished, dumped.insert(t.id).inserted {
                        let raw = t.samples.map { s in
                            String(format: "+%.2fs:%.0fMB/s", s.time.timeIntervalSince(t.startedAt), s.bytesPerSecond / 1e6)
                        }
                        print("          raw samples: \(raw.joined(separator: " "))")
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime(monitor) { RunLoop.main.run() }
        exit(0)
    }

    static func describe(_ t: Transfer) -> String {
        let state = t.isFinished ? (t.wasCancelled ? "CANCELLED" : "FINISHED")
            : t.isPreparing ? "preparing" : "copying"
        var s = "\(state) \"\(t.displayName)\" -> \(t.destinationFolder.path)  "
            + "\(bytes(t.bytesCompleted))/\(bytes(t.bytesTotal)) "
            + String(format: "(%.1f%%)", t.fractionCompleted * 100)
            + "  speed=\(rate(t.bytesPerSecond))"
        if let last = t.samples.last { s += " raw=\(rate(last.bytesPerSecond))" }
        if let avg = t.averageBytesPerSecond { s += " avg=\(rate(avg))" }
        s += " samples=\(t.samples.count)"
        if t.usesWindowFallback { s += " src=window" }
        if t.itemNames.count > 1 { s += " items=\(t.itemNames)" }
        return s
    }

    private static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private static func rate(_ bps: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }
}
