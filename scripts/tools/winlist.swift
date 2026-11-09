// Prints on-screen windows of Finder and FinderSpeed as JSON lines (CG coordinates, top-left origin). Owner: zeus.
import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for (z, w) in list.enumerated() {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == "Finder" || owner == "FinderSpeed" else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let o: [String: Any] = ["z": z, "owner": owner, "id": w[kCGWindowNumber as String] ?? 0,
        "layer": w[kCGWindowLayer as String] ?? 0, "alpha": w[kCGWindowAlpha as String] ?? 1,
        "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0]
    let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    print(String(data: d, encoding: .utf8)!)
}
