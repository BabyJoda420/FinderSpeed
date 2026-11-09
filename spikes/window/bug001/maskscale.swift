// BUG-001 probe (apollo): NSVisualEffectView.maskImage when the mask's pixel size != its point size
// (what a 1x bitmap mask becomes on a 2x display). Band-like mask: left 16 pt column + bottom 4 pt.
import AppKit
setvbuf(stdout, nil, _IOLBF, 0)
let origin = CGPoint(x: 600, y: 120)
let W = 300, H = 40
func maskCG(scale: Double) -> CGImage {
    let pw = Int(Double(W) * scale), ph = Int(Double(H) * scale)
    let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 16 * scale, height: Double(ph)))          // left column
    ctx.fill(CGRect(x: 0, y: 0, width: Double(pw), height: 4 * scale))           // bottom strip (CG y-up)
    return ctx.makeImage()!
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let ph = NSScreen.screens[0].frame.height
    let fr = NSRect(x: origin.x, y: ph - origin.y - CGFloat(H), width: CGFloat(W), height: CGFloat(H))
    let pat = NSWindow(contentRect: fr, styleMask: [.borderless], backing: .buffered, defer: false)
    let pv = NSView(frame: NSRect(origin: .zero, size: fr.size)); pv.wantsLayer = true; pv.layer?.backgroundColor = NSColor.white.cgColor
    pat.contentView = pv; pat.orderFrontRegardless()
    let w = NSPanel(contentRect: fr, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
    let ev = NSVisualEffectView(frame: NSRect(origin: .zero, size: fr.size)); ev.material = .windowBackground; ev.blendingMode = .behindWindow; ev.state = .active
    w.contentView = ev; w.order(.above, relativeTo: pat.windowNumber)
    print("backingScaleFactor \(w.backingScaleFactor)")
    let scales = [1.0, 2.0, 0.5]; var i = 0
    func step() {
        guard i < scales.count else { exit(0) }
        ev.maskImage = NSImage(cgImage: maskCG(scale: scales[i]), size: NSSize(width: W, height: H))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R\(Int(origin.x)),\(Int(origin.y)),\(W),\(H)", "mask-scale\(scales[i]).png"]
            try? p.run(); p.waitUntilExit(); i += 1; step()
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
    app.run()
}
