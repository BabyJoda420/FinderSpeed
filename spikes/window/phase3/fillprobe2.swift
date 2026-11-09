// Places fill candidates as stripes right under Finder's Progress window, then screencaptures. (apollo)
import AppKit
import ApplicationServices
setvbuf(stdout, nil, _IOLBF, 0)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fill.png"
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first!
    let ax = AXUIElementCreateApplication(finder.processIdentifier)
    var win: AXUIElement?
    for _ in 0..<300 {
        win = ((attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first { (attr($0, "AXIdentifier") as? String) == "Progress" }
        if win != nil { break }; usleep(50_000)
    }
    guard let w = win else { print("no progress window"); exit(2) }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(attr(w, kAXPositionAttribute) as! AXValue, .cgPoint, &p); AXValueGetValue(attr(w, kAXSizeAttribute) as! AXValue, .cgSize, &s)
    print("finder frame \(p) \(s) main=\(attr(w, kAXMainAttribute) as? Bool ?? false) focused=\(attr(w, kAXFocusedAttribute) as? Bool ?? false) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")")
    let primaryH = NSScreen.screens[0].frame.height
    let extra = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "0") ?? 0
    let frame = NSRect(x: p.x, y: primaryH - p.y - s.height - 120, width: s.width, height: 120 + extra)
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.level = .normal
    let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
    let names = ["full"]
    for (i, n) in names.enumerated() {
        let r = NSRect(origin: .zero, size: frame.size)
        if n == "solidWBC" {
            let v = NSView(frame: r); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; root.addSubview(v)
        } else {
            let v = NSVisualEffectView(frame: r)
            v.material = n == "underWin" ? .underWindowBackground : .windowBackground
            v.blendingMode = .behindWindow
            v.state = n == "active" ? .active : n == "inactive" ? .inactive : .followsWindowActiveState
            if n == "underWin" { v.state = .inactive }
            root.addSubview(v)
        }
    }
    panel.contentView = root
    panel.order(extra > 0 ? .below : .above, relativeTo: Int({ var id: CGWindowID = 0; _ = _AXUIElementGetWindow(w, &id); return id }()))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        let r = "\(Int(p.x)),\(Int(p.y)),\(Int(s.width)),\(Int(s.height) + 130)"
        let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); pr.arguments = ["-x", "-R\(r)", out]
        try? pr.run(); pr.waitUntilExit(); print("captured \(r)"); exit(0)
    }
    app.run()
}
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement, _ w: UnsafeMutablePointer<CGWindowID>) -> AXError
