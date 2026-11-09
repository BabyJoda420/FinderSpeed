// Takes app activation for N seconds without showing any window, so Finder becomes inactive. (apollo)
import AppKit
let secs = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "8") ?? 8
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    DispatchQueue.main.async { app.activate(ignoringOtherApps: true) }
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    app.run()
}
