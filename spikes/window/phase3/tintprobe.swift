// Captures NSVisualEffectView materials in windows at given frames (by window id). (apollo)
import AppKit
setvbuf(stdout, nil, _IOLBF, 0)
// args: x y w h (CG top-left coords) label
let a = CommandLine.arguments
let r = CGRect(x: Double(a[1])!, y: Double(a[2])!, width: Double(a[3])!, height: Double(a[4])!)
let label = a[5]
let mats: [(String, NSVisualEffectView.Material)] = [("windowBackground", .windowBackground), ("underWindowBackground", .underWindowBackground),
  ("contentBackground", .contentBackground), ("sidebar", .sidebar), ("titlebar", .titlebar), ("headerView", .headerView), ("sheet", .sheet), ("menu", .menu), ("popover", .popover), ("hudWindow", .hudWindow)]
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let ph = NSScreen.screens[0].frame.height
    let frame = NSRect(x: r.minX, y: ph - r.minY - r.height, width: r.width, height: r.height)
    let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.level = .normal
    let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size)); v.blendingMode = .behindWindow; v.state = .active
    w.contentView = v
    w.orderBack(nil)   // behind everything of ours; captured by id anyway
    var i = 0
    func step() {
        guard i < mats.count else { exit(0) }
        v.material = mats[i].1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let f = "/tmp/tint.png"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", "-o", "-l\(w.windowNumber)", f]
            try? p.run(); p.waitUntilExit()
            if let img = NSImage(contentsOfFile: f), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let rep = NSBitmapImageRep(cgImage: cg); let c = rep.colorAt(x: cg.width / 2, y: cg.height / 2)!.usingColorSpace(.sRGB)!
                print(String(format: "%@ %-22@ (%d,%d,%d)", label, mats[i].0, Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())))
            }
            i += 1; step()
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
    app.run()
}
