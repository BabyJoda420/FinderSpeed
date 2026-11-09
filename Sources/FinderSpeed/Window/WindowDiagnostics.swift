// Window/WindowDiagnostics.swift (owner: apollo)
//
// Diagnostic log for the Window module. Enabled with FINDERSPEED_DEBUG_WINDOW=1 (environment), or
// `defaults write <bundle id> FinderSpeedDebugWindow -bool YES` for the installed app. Writes to
// ~/Library/Logs/FinderSpeed.log (and stdout). Thread-safe; cheap when disabled.
//
// What it records (BUG-001): screens (scale, colour space, notch insets), slow or failing AX calls
// to Finder, observer events, panel show/hide with reasons, and the panel windows' alpha and frames.

import AppKit
import Foundation

enum WindowDiagnostics {
    /// On with FINDERSPEED_DEBUG_WINDOW=1, the FinderSpeedDebugWindow default, or by default in
    /// diagnostic builds (bundle version containing "diag", e.g. 0.1.1-diag). The default can still
    /// switch a diag build off: `defaults write <bundle id> FinderSpeedDebugWindow -bool NO`.
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["FINDERSPEED_DEBUG_WINDOW"] != nil { return true }
        if UserDefaults.standard.object(forKey: "FinderSpeedDebugWindow") != nil {
            return UserDefaults.standard.bool(forKey: "FinderSpeedDebugWindow")
        }
        return isDiagnosticBuild
    }()

    static var isDiagnosticBuild: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let versions = [info["CFBundleShortVersionString"], info["CFBundleVersion"]].compactMap { $0 as? String }
        return versions.contains { $0.lowercased().contains("diag") }
    }

    static let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FinderSpeed.log")

    private static let queue = DispatchQueue(label: "finder-speed.diagnostics")
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var started = false
    private static let t0 = Date()

    static func log(_ category: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        let now = Date()
        let thread = Thread.isMainThread ? "main" : "bg"
        queue.async {
            if !started { start() }
            let f = DateFormatter.cached
            let line = "\(f.string(from: now)) +\(String(format: "%.3f", now.timeIntervalSince(t0))) [\(category)/\(thread)] \(text)\n"
            print(line, terminator: ""); fflush(stdout)
            if let data = line.data(using: .utf8) { handle?.write(data) }
        }
    }

    /// One-time environment dump (screens etc.). Call on the main actor.
    @MainActor static func logEnvironment(reason: String) {
        guard enabled else { return }
        let info = ProcessInfo.processInfo
        log("env", "\(reason): macOS \(info.operatingSystemVersionString), pid \(info.processIdentifier), "
            + "AX trusted \(AXIsProcessTrusted()), screen recording \(CGPreflightScreenCaptureAccess()), "
            + "appearance \(NSApp.effectiveAppearance.name.rawValue)")
        for (i, s) in NSScreen.screens.enumerated() {
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            var extra = ""
            if #available(macOS 12.0, *) {
                extra = " safeAreaInsets(top \(s.safeAreaInsets.top)) auxTopLeft \(s.auxiliaryTopLeftArea.map { "\($0)" } ?? "nil")"
                    + " auxTopRight \(s.auxiliaryTopRightArea.map { "\($0)" } ?? "nil")"
            }
            log("env", "screen[\(i)] id \(id) \"\(s.localizedName)\" frame \(s.frame) visible \(s.visibleFrame) "
                + "scale \(s.backingScaleFactor) colorSpace \(s.colorSpace?.localizedName ?? "nil")"
                + " builtin \(CGDisplayIsBuiltin(id) != 0)\(extra)")
        }
    }

    private static func start() {
        started = true
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the file bounded: start over above 5 MB.
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber, size.intValue > 5_000_000 {
            try? fm.removeItem(at: logURL)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        let info = Bundle.main.infoDictionary ?? [:]
        let header = "\n===== FinderSpeed window diagnostics, \(Date()), version \(info["CFBundleShortVersionString"] ?? "-") (\(info["CFBundleVersion"] ?? "-")) =====\n"
        print(header, terminator: "")
        handle?.write(header.data(using: .utf8)!)
    }
}

private extension DateFormatter {
    static let cached: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
}
