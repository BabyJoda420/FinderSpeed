// Window/FinderBackgroundSampler.swift (owner: apollo)
//
// Finder's progress window background is a wallpaper-tinted material. The tint is computed from the
// desktop region under each window's frame (measured: one uniform colour per window, and it changes
// with the window's position), so NO material in our own window can reproduce Finder's exact colour.
// When the Screen Recording permission is already granted, this reads Finder's actual on-screen
// background pixel (ScreenCaptureKit, our own windows excluded) so the panel can use that exact colour.
// It never asks for the permission. Without it, the panel falls back to the closest material.

import AppKit
import ScreenCaptureKit

@MainActor
final class FinderBackgroundSampler {
    /// Window-relative (top-left) rect of plain background in Finder's progress window: the left
    /// margin, left of the 34 pt icon (x 17) and below the title bar (y 32).
    static let sampleRect = CGRect(x: 4, y: 46, width: 8, height: 8)

    var debugLogging = false
    private var inFlight = false
    private var pending: (CGWindowID, [CGWindowID], (CGColor?) -> Void)?

    /// `FINDERSPEED_NO_SAMPLE=1` forces the material fallback (for testing).
    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["FINDERSPEED_NO_SAMPLE"] == nil && CGPreflightScreenCaptureAccess()
    }

    /// Samples Finder's background. `completion` runs on the main actor with nil if unavailable.
    func sample(finderWindow: CGWindowID, excluding ours: [CGWindowID], completion: @escaping (CGColor?) -> Void) {
        guard Self.isAvailable else { completion(nil); return }
        if inFlight { pending = (finderWindow, ours, completion); return }
        inFlight = true
        let t0 = Date()
        Task { @MainActor in
            let color = await Self.capture(finderWindow: finderWindow, excluding: ours)
            if debugLogging {
                let comps = color?.components?.map { Int(($0 * 255).rounded()) } ?? []
                print(String(format: "[sampler] %.0f ms -> %@", Date().timeIntervalSince(t0) * 1000, comps.description))
            }
            inFlight = false
            completion(color)
            if let (f, o, c) = pending { pending = nil; sample(finderWindow: f, excluding: o, completion: c) }
        }
    }

    private static func capture(finderWindow: CGWindowID, excluding ours: [CGWindowID]) async -> CGColor? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let finder = content.windows.first(where: { $0.windowID == finderWindow }) else { return nil }
            let frame = finder.frame   // global, top-left origin
            guard let display = content.displays.first(where: { $0.frame.intersects(frame) }) else { return nil }
            let excluded = content.windows.filter { ours.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let cfg = SCStreamConfiguration()
            let r = sampleRect.offsetBy(dx: frame.minX - display.frame.minX, dy: frame.minY - display.frame.minY)
            cfg.sourceRect = r
            cfg.width = Int(r.width); cfg.height = Int(r.height)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return medianColor(image)
        } catch {
            return nil
        }
    }

    /// Median of each channel, in the image's own colour space (the display's), so the colour
    /// round-trips to the same screen pixels.
    private static func medianColor(_ image: CGImage) -> CGColor? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let w = image.width, h = image.height
        guard w > 0, h > 0, space.model == .rgb,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
        for i in 0..<(w * h) { rs.append(p[i * 4]); gs.append(p[i * 4 + 1]); bs.append(p[i * 4 + 2]) }
        func med(_ a: [UInt8]) -> CGFloat { CGFloat(a.sorted()[a.count / 2]) / 255 }
        return CGColor(colorSpace: space, components: [med(rs), med(gs), med(bs), 1])
    }
}
