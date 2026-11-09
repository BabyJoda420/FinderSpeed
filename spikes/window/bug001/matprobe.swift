// BUG-001 probe (apollo): does NSVisualEffectView(.windowBackground, .behindWindow) stay opaque and honour
// maskImage in each state, over sharp content, in a non-active accessory app? Captures each state.
import AppKit
setvbuf(stdout, nil, _IOLBF, 0)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let origin = CGPoint(x: 600, y: 120)   // CG top-left of the test area
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let ph = NSScreen.screens[0].frame.height
    func frame(_ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: origin.x, y: ph - origin.y - h, width: w, height: h) }
    // Sharp pattern window (stripes + text), behind.
    let pat = NSWindow(contentRect: frame(300, 120), styleMask: [.borderless], backing: .buffered, defer: false)
    let pv = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120)); pv.wantsLayer = true
    pv.layer?.backgroundColor = NSColor.white.cgColor
    for i in 0..<15 { let s = CALayer(); s.frame = CGRect(x: i * 20, y: 0, width: 10, height: 120); s.backgroundColor = NSColor.systemRed.cgColor; pv.layer?.addSublayer(s) }
    pat.contentView = pv; pat.level = .normal; pat.orderFrontRegardless()
    // Effect window on top, mask = left half only.
    let w = NSPanel(contentRect: frame(300, 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.level = .normal
    let ev = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
    ev.material = .windowBackground; ev.blendingMode = .behindWindow
    let mask = NSImage(size: NSSize(width: 300, height: 120), flipped: false) { r in
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 150, height: 120).fill(); return true }
    ev.maskImage = mask
    w.contentView = ev; w.order(.above, relativeTo: pat.windowNumber)
    let states: [(String, NSVisualEffectView.State)] = [("active", .active), ("inactive", .inactive), ("follows", .followsWindowActiveState)]
    var i = 0
    func step() {
        guard i < states.count else { exit(0) }
        ev.state = states[i].1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R\(Int(origin.x)),\(Int(origin.y)),300,120", "\(out)/mat-\(states[i].0).png"]
            try? p.run(); p.waitUntilExit(); i += 1; step()
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
    app.run()
}
