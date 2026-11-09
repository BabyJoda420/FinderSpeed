// App/main.swift (owner: zeus)
// Entry point. `--engine-debug` runs Athena's headless engine logger; otherwise starts the menu bar app.

import AppKit

if EngineDebug.isRequested() {
    EngineDebug.run()
}

// --render-demo <dir>: write PNG snapshots of the panel (light/dark × collapsed/expanded) and exit.
if let i = CommandLine.arguments.firstIndex(of: "--render-demo") {
    let dir = URL(fileURLWithPath: CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "build/snapshots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do { try MainActor.assumeIsolated { try UISnapshot.renderDemo(to: dir) } } catch { print("render failed: \(error)"); exit(1) }
    print("Rendered demo snapshots to \(dir.path)"); exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    withExtendedLifetime(delegate) { app.run() }
}
