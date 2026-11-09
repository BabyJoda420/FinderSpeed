// Window/WindowChrome.swift (owner: apollo)
//
// Draws the chrome that makes the speed panel and Finder's progress window look like ONE window:
// the outline ring, the light inner rim and the window shadow of the combined shape
// (Finder's window + our body below it), using measured profiles (WindowChromeData.swift).
//
// Model (all values are alpha, 0...1, at 1 pt per pixel):
//  * A_T(x, y): what the window server would draw around a single window with the combined shape.
//    A tall window's side profile is constant more than K rows from its bottom (measured: <= 3/255
//    variation), and its bottom block is the same for any height (<= 2/255), so A_T = the steady side
//    profile, or the bottom block anchored at the combined bottom edge.
//  * A_F(x, y): what the window server already draws around Finder's window alone (its bottom block).
//  * Our shadow window adds black alpha s on top of A_F so that the result equals A_T:
//        1 - (1 - s)(1 - A_F) = u,   u = (A_T - cov) / (1 - cov)   (cov = our body's coverage there)
//    so s = 1 - (1 - u) / (1 - A_F).
//  * Edge pixels of the body get a white (dark mode rim) or black overlay on the fill, so they equal
//    the reference rendering for ANY fill colour.
//
// Coordinates here: x from Finder's left edge, yb rows relative to Finder's bottom edge (0 = first
// row below Finder), top-down. The "band" is the rows yb in [-band, 0) that overlap Finder's window.

import AppKit
import CoreGraphics

struct WindowChromeProfile {
    struct Key: Hashable { let dark: Bool; let active: Bool }

    let padX: Int            // shadow extent left/right
    let padBelow: Int        // shadow extent below
    let rowsAbove: Int       // K: rows of the bottom block above the bottom edge
    let shortRowsAbove: Int  // rows of Finder's own block above its bottom edge
    let columns: Int         // Cx: block columns from the left edge; further columns repeat the last
    let cornerSize: Int
    let steady: [Float]      // [d] = alpha at x = -1 - d
    let tall: [Float]        // [(db + K) * width + (dx + padX)]
    let short: [Float]       // [(db + shortRowsAbove) * width + (dx + padX)]
    let coverage: [Float]    // [(db + cornerSize) * cornerSize + dx]
    let overlay: [Float]     // same layout; >0 white alpha, <0 black alpha
    let overlaySide: [Float] // columns 0...2 of a straight left edge
    let overlayBottom: [Float] // rows -1...-3 of a straight bottom edge

    var blockWidth: Int { padX + columns }

    init(padX: Int, padBelow: Int, rowsAbove: Int, shortRowsAbove: Int, columns: Int, cornerSize: Int,
         steady: String, tall: String, short: String, coverage: String, overlay: String,
         overlaySide: String, overlayBottom: String) {
        func bytes(_ s: String) -> [UInt8] { [UInt8](Data(base64Encoded: s) ?? Data()) }
        func alpha(_ s: String) -> [Float] { bytes(s).map { Float($0) / 255 } }
        func signed(_ s: String) -> [Float] { bytes(s).map { (Float($0) - 128) / 127 } }
        self.padX = padX; self.padBelow = padBelow; self.rowsAbove = rowsAbove
        self.shortRowsAbove = shortRowsAbove; self.columns = columns; self.cornerSize = cornerSize
        self.steady = alpha(steady); self.tall = alpha(tall); self.short = alpha(short)
        self.coverage = alpha(coverage); self.overlay = signed(overlay)
        self.overlaySide = signed(overlaySide); self.overlayBottom = signed(overlayBottom)
    }

    static func profile(dark: Bool, active: Bool) -> WindowChromeProfile {
        measured[Key(dark: dark, active: active)]!
    }

    /// Bottom block lookup. `dx` is the mirrored distance from the nearest side edge (negative =
    /// outside), `db` the row relative to the bottom edge.
    @inline(__always) func tallAlpha(dx: Int, db: Int) -> Float {
        let c = min(dx, columns - 1) + padX
        return tall[(db + rowsAbove) * blockWidth + c]
    }

    @inline(__always) func shortAlpha(dx: Int, db: Int) -> Float {
        let c = min(dx, columns - 1) + padX
        return short[(db + shortRowsAbove) * blockWidth + c]
    }

    /// Coverage of the window content in a bottom corner (1 outside the corner block).
    @inline(__always) func cornerCoverage(dx: Int, db: Int) -> Float {
        guard dx < cornerSize, db >= -cornerSize, db < 0 else { return 1 }
        return coverage[(db + cornerSize) * cornerSize + dx]
    }

    @inline(__always) func cornerOverlay(dx: Int, db: Int) -> Float? {
        guard dx < cornerSize, db >= -cornerSize, db < 0 else { return nil }
        return overlay[(db + cornerSize) * cornerSize + dx]
    }

    /// For each band row (index 0 = yb -cornerSize), how many columns from each side edge differ
    /// from a flat fill in Finder's own bottom corner (its curve + rim), plus one pixel of margin.
    var curveWidths: [Int] {
        (0..<cornerSize).map { r in
            var w = 0
            for dx in 0..<cornerSize {
                let i = r * cornerSize + dx
                if coverage[i] < 0.999 || abs(overlay[i]) > 0.004 { w = dx + 1 }
            }
            return w == 0 ? 0 : min(cornerSize, w + 1)
        }
    }
}

enum WindowChromeRenderer {
    /// Rows of the body window / shadow window that overlap Finder's window (above its bottom edge).
    static let bandHeight = 24
    /// Rows along Finder's bottom edge that are always painted (they cover Finder's bottom rim).
    static let stripHeight = 4
    /// Width of each band corner patch (Finder's bottom-corner curve is narrower than this).
    static let cornerPatchWidth = 24

    struct Images {
        let shadow: CGImage   // (width + 2 padX) x (band + height + padBelow), black with alpha
        let mask: CGImage     // width x (band + height): where the body fill is painted
        let overlay: CGImage  // width x (band + height): rim (white) / dark edge overlay
        let padX: Int
        let padBelow: Int
    }

    /// `width`: Finder's window width; `height`: our body height below Finder's bottom edge (points).
    /// `scale`: pixels per point of the target screen (BUG-001 (e)). The measured data is 1 px per
    /// point, so the chrome is evaluated at 1x and each point is replicated to scale x scale pixels; the
    /// images are `scale` times larger in pixels (point geometry unchanged).
    static func render(profile p: WindowChromeProfile, width W: Int, height H: Int, scale: Int) -> Images? {
        guard let base = render(profile: p, width: W, height: H) else { return nil }
        guard scale > 1 else { return base }
        // Replicate pixels (no interpolation): the 1 pt outline ring, the rim and the masks keep hard
        // edges on point boundaries, and each point averages to exactly the measured 1x value.
        guard let s = upsample(base.shadow, scale, quality: .none), let m = upsample(base.mask, scale, quality: .none),
              let o = upsample(base.overlay, scale, quality: .none) else { return nil }
        return Images(shadow: s, mask: m, overlay: o, padX: base.padX, padBelow: base.padBelow)
    }

    static func upsample(_ image: CGImage, _ scale: Int, quality: CGInterpolationQuality) -> CGImage? {
        let w = image.width * scale, h = image.height * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = quality
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 1 px per point.
    static func render(profile p: WindowChromeProfile, width W: Int, height H: Int) -> Images? {
        let band = bandHeight
        let curve = p.curveWidths   // per band row (last `cornerSize` rows above Finder's bottom)

        // Body coverage at (x, yb). Band: only Finder's corner curve area and the bottom strip.
        func bodyCoverage(x: Int, yb: Int) -> Float {
            guard x >= 0, x < W, yb < H else { return 0 }
            let dx = min(x, W - 1 - x)
            if yb < 0 {
                if yb >= -stripHeight { return 1 }
                let r = yb + p.cornerSize
                guard r >= 0 else { return 0 }
                return dx < curve[r] ? 1 : 0
            }
            return p.cornerCoverage(dx: dx, db: yb - H)
        }
        // Coverage of the combined shape (Finder + body), for the shadow model.
        func combinedCoverage(x: Int, yb: Int) -> Float {
            guard x >= 0, x < W, yb < H else { return 0 }
            if yb < 0 { return 1 }
            return p.cornerCoverage(dx: min(x, W - 1 - x), db: yb - H)
        }

        // Shadow image.
        let sw = W + 2 * p.padX, sh = band + H + p.padBelow
        var shadow = [UInt8](repeating: 0, count: sw * sh * 4)
        for py in 0..<sh {
            let yb = py - band
            for px in 0..<sw {
                let x = px - p.padX
                let cov = combinedCoverage(x: x, yb: yb)
                if cov >= 0.999 { continue }
                let dx = x < 0 ? x : (x >= W ? (W - 1) - x : min(x, W - 1 - x))
                // Target: the combined window.
                let dbT = yb - H
                let aT: Float
                if dbT >= -p.rowsAbove { aT = p.tallAlpha(dx: dx, db: dbT) }
                else if dx < 0 { aT = p.steady[min(-dx - 1, p.steady.count - 1)] }
                else { aT = 1 }
                // Already there: Finder's window alone.
                let aF: Float
                if yb >= p.padBelow { aF = 0 }
                else if yb >= -p.shortRowsAbove { aF = p.shortAlpha(dx: dx, db: yb) }
                else { aF = dx < 0 ? p.steady[min(-dx - 1, p.steady.count - 1)] : 1 }
                if aF >= 0.999 { continue }
                let u = (aT - cov) / (1 - cov)
                let s = max(0, min(1, 1 - (1 - u) / (1 - aF)))
                if s > 0 { shadow[(py * sw + px) * 4 + 3] = UInt8((s * 255).rounded()) }
            }
        }

        // Fill mask and edge overlay (premultiplied RGBA).
        let bw = W, bh = band + H
        var mask = [UInt8](repeating: 0, count: bw * bh * 4)
        var overlay = [UInt8](repeating: 0, count: bw * bh * 4)
        for py in 0..<bh {
            let yb = py - band
            for x in 0..<bw {
                let c = bodyCoverage(x: x, yb: yb)
                guard c > 0 else { continue }
                let i = (py * bw + x) * 4
                let a = UInt8((c * 255).rounded())
                mask[i] = a; mask[i + 1] = a; mask[i + 2] = a; mask[i + 3] = a
                // Edge overlay: corner table, else straight side columns / straight bottom rows.
                let dx = min(x, W - 1 - x)
                var o: Float = 0
                if yb >= 0, let co = p.cornerOverlay(dx: dx, db: yb - H) {
                    o = co
                } else {
                    if dx < 3 { o = p.overlaySide[dx] }
                    if yb >= 0 && yb >= H - 3 {
                        let b = p.overlayBottom[H - 1 - yb]
                        if abs(b) > abs(o) { o = b }
                    }
                }
                guard abs(o) > 0.002 else { continue }
                let oa = abs(o) * c
                let ab = UInt8((oa * 255).rounded())
                if o > 0 { overlay[i] = ab; overlay[i + 1] = ab; overlay[i + 2] = ab }
                overlay[i + 3] = ab
            }
        }
        guard let s = makeImage(&shadow, sw, sh), let m = makeImage(&mask, bw, bh),
              let o = makeImage(&overlay, bw, bh) else { return nil }
        return Images(shadow: s, mask: m, overlay: o, padX: p.padX, padBelow: p.padBelow)
    }

    private static func makeImage(_ bytes: inout [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
