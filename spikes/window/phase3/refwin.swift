// Reference window for chrome measurements (apollo, phase 3).
// Usage: refwin dark|light key|nokey outdir   -> captures shadow.png / noshadow.png of a 404x88 titled window
import AppKit
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let dark = args.count > 1 ? args[1] == "dark" : true
let key = args.count > 2 ? args[2] == "key" : false
let out = args.count > 3 ? args[3] : "."
let height = args.count > 4 ? Double(args[4]) ?? 88 : 88
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(key ? .regular : .accessory)
    let w = NSWindow(contentRect: NSRect(x: 300, y: 250, width: 404, height: height - 32),
                     styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    w.title = ""
    w.isReleasedWhenClosed = false
    if key { w.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true) } else { w.orderFrontRegardless() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        print("frame \(w.frame) key=\(w.isKeyWindow) main=\(w.isMainWindow) wid=\(w.windowNumber)")
        let wid = w.windowNumber
        for (name, flags) in [("shadow", ["-x", "-l\(wid)"]), ("noshadow", ["-x", "-o", "-l\(wid)"])] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = flags + ["\(out)/\(name).png"]; try? p.run(); p.waitUntilExit()
        }
        exit(0)
    }
    app.run()
}
