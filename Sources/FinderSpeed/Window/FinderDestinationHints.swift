// Window/FinderDestinationHints.swift (owner: apollo)
//
// Feeds the Engine with likely destination folders when Finder's progress window appears.
// The Engine's NSProgress subscriptions are not recursive (Spike A), so a copy into an arbitrary
// folder is only seen once that exact folder is subscribed. Late subscription delivers running
// copies at once, so asking Finder after the window appears (~3 s into the copy) is fine.
//
// Sources of candidates:
//  1. Finder AppleScript: the insertion location and the target folder of every Finder window.
//     Needs the Automation permission for Finder (the bundled app needs NSAppleEventsUsageDescription).
//  2. The destination name in each row title ("Copying 6 items to “apollo”") is matched against
//     the candidates, their direct subfolders (a drop onto a folder inside a window), mounted
//     volumes and the standard user folders.

import AppKit
import Foundation

@MainActor
public final class FinderDestinationHints {

    /// Destination display name (from a row title) -> resolved folder.
    public private(set) var resolvedDestinations: [String: URL] = [:]
    /// Called when a row's destination name is resolved to a folder.
    public var onResolve: ((_ name: String, _ folder: URL) -> Void)?
    public var debugLogging = false

    private let noteDestination: @MainActor (URL) -> Void
    private let runner = AppleScriptRunner()
    private var queryInFlight = false
    private var lastQueryAt: Date = .distantPast
    private var attempts: [String: Int] = [:]          // unresolved name -> queries made for it
    private var observerToken: FinderProgressWindowObserver.HandlerToken?
    private weak var observer: FinderProgressWindowObserver?
    private var permissionDenied = false

    private static let minQueryInterval: TimeInterval = 1.5
    private static let maxAttemptsPerName = 3

    public init(noteDestination: @escaping @MainActor (URL) -> Void) {
        self.noteDestination = noteDestination
    }

    public convenience init(monitor: TransferMonitor) {
        self.init { [weak monitor] url in monitor?.noteFinderDestination(url) }
    }

    /// Queries Finder whenever the progress window appears, and again (rate limited) while a
    /// row's destination name is still unresolved.
    public func attach(to observer: FinderProgressWindowObserver) {
        if let t = observerToken { self.observer?.removeHandler(t) }
        self.observer = observer
        observerToken = observer.addHandler { [weak self] event, info in
            guard let self else { return }
            switch event {
            case .appeared:
                self.attempts.removeAll()
                self.query(force: true)
            case .rowsChanged:
                if self.hasUnresolved(info?.rows ?? []) { self.query(force: false) }
            default:
                break
            }
        }
        if observer.window != nil { query(force: true) }
    }

    /// The resolved destination folder of a progress-window row, if known.
    public func destination(for row: FinderProgressWindowObserver.Row) -> URL? {
        row.destinationName.flatMap { resolvedDestinations[$0] }
    }

    /// Asks Finder now (still asynchronous).
    public func requestNow() { query(force: true) }

    // MARK: Private

    private func log(_ s: @autoclosure () -> String) {
        if debugLogging { print("[hints] \(s())"); fflush(stdout) }
    }

    private func hasUnresolved(_ rows: [FinderProgressWindowObserver.Row]) -> Bool {
        rows.contains { r in
            guard let n = r.destinationName else { return false }
            return resolvedDestinations[n] == nil && (attempts[n] ?? 0) < Self.maxAttemptsPerName
        }
    }

    private func query(force: Bool) {
        guard !permissionDenied, !queryInFlight else { return }
        if !force && Date().timeIntervalSince(lastQueryAt) < Self.minQueryInterval { return }
        for r in observer?.window?.rows ?? [] {
            if let n = r.destinationName, resolvedDestinations[n] == nil { attempts[n, default: 0] += 1 }
        }
        queryInFlight = true
        lastQueryAt = Date()
        let started = Date()
        runner.finderCandidateFolders { [weak self] result in
            guard let self else { return }
            self.queryInFlight = false
            switch result {
            case .failure(let err):
                self.log("AppleScript failed: \(err)")
                if err.code == -1743 { self.permissionDenied = true }   // errAEEventNotPermitted
                self.resolve(candidates: [])
            case .success(let paths):
                self.log(String(format: "AppleScript %.0f ms -> %@", Date().timeIntervalSince(started) * 1000,
                                paths.description))
                self.resolve(candidates: paths.map { URL(fileURLWithPath: $0, isDirectory: true) })
            }
        }
    }

    private func resolve(candidates: [URL]) {
        for c in candidates { noteDestination(c) }
        let rows = observer?.window?.rows ?? []
        let names = Set(rows.compactMap(\.destinationName))
        for name in names where resolvedDestinations[name] == nil {
            if let url = Self.match(name: name, candidates: candidates) {
                resolvedDestinations[name] = url
                noteDestination(url)
                log("resolved “\(name)” -> \(url.path)")
                onResolve?(name, url)
            } else {
                log("could not resolve “\(name)”")
            }
        }
        // Forget names that are no longer shown, so a later copy to a same-named folder elsewhere
        // is resolved afresh.
        if !rows.isEmpty { resolvedDestinations = resolvedDestinations.filter { names.contains($0.key) } }
    }

    private static func matches(_ url: URL, _ name: String) -> Bool {
        url.lastPathComponent == name || FileManager.default.displayName(atPath: url.path) == name
    }

    /// Picks the folder whose (display) name is `name`. Order of preference: a candidate itself,
    /// a direct subfolder of a candidate, a mounted volume, a top-level folder on a volume, a standard
    /// user folder.
    static func match(name: String, candidates: [URL]) -> URL? {
        let fm = FileManager.default
        if let c = candidates.first(where: { matches($0, name) }) { return c }
        for c in candidates {
            let sub = c.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue { return sub }
        }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        if let v = volumes.first(where: { matches($0, name) }) { return v }
        for v in volumes {   // a top-level folder on a volume (external drives, NAS shares)
            let sub = v.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue { return sub }
        }
        let dirs: [FileManager.SearchPathDirectory] = [.desktopDirectory, .downloadsDirectory, .documentDirectory,
                                                       .moviesDirectory, .musicDirectory, .picturesDirectory,
                                                       .applicationDirectory]
        let standard = [fm.homeDirectoryForCurrentUser] + dirs.flatMap { fm.urls(for: $0, in: .userDomainMask) }
            + [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        return standard.first { matches($0, name) }
    }
}

/// Runs NSAppleScript on a private serial queue; results are delivered on the main actor.
private final class AppleScriptRunner: @unchecked Sendable {
    struct ScriptError: Error, CustomStringConvertible {
        let code: Int
        let message: String
        var description: String { "\(code): \(message)" }
    }

    private let queue = DispatchQueue(label: "finder-speed.applescript", qos: .userInitiated)
    private var script: NSAppleScript?   // only touched on `queue`

    private static let source = """
    tell application "Finder"
        set out to {}
        try
            set end of out to POSIX path of (insertion location as alias)
        end try
        repeat with w in (every Finder window)
            try
                set end of out to POSIX path of (target of w as alias)
            end try
        end repeat
        return out
    end tell
    """

    func finderCandidateFolders(_ completion: @escaping @MainActor (Result<[String], ScriptError>) -> Void) {
        queue.async { [self] in
            let result = run()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    private func run() -> Result<[String], ScriptError> {
        if script == nil {
            script = NSAppleScript(source: Self.source)
            var err: NSDictionary?
            if script?.compileAndReturnError(&err) == false {
                script = nil
                return .failure(Self.error(err))
            }
        }
        var err: NSDictionary?
        guard let desc = script?.executeAndReturnError(&err) else { return .failure(Self.error(err)) }
        var paths: [String] = []
        if desc.numberOfItems > 0 {
            for i in 1...desc.numberOfItems {
                if let s = desc.atIndex(i)?.stringValue { paths.append(s) }
            }
        } else if let s = desc.stringValue, !s.isEmpty {
            paths.append(s)
        }
        // Dedupe, keep order.
        var seen = Set<String>()
        return .success(paths.filter { seen.insert($0).inserted })
    }

    private static func error(_ d: NSDictionary?) -> ScriptError {
        ScriptError(code: (d?[NSAppleScript.errorNumber] as? Int) ?? -1,
                    message: (d?[NSAppleScript.errorMessage] as? String) ?? "unknown")
    }
}
