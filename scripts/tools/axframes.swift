// Dumps frames of the elements in Finder's Progress window, relative to the window. Owner: zeus.
import AppKit
import ApplicationServices
guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { exit(1) }
let app = AXUIElementCreateApplication(finder.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func dump(_ e: AXUIElement, _ origin: CGPoint, _ depth: Int) {
    let f = frame(e); let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let v = (attr(e, kAXValueAttribute) as? String) ?? (attr(e, kAXDescriptionAttribute) as? String) ?? ""
    print(String(repeating: "  ", count: depth) + "\(role) x=\(Int(f.minX - origin.x)) y=\(Int(f.minY - origin.y)) w=\(Int(f.width)) h=\(Int(f.height)) \(v.prefix(50))")
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { dump(c, origin, depth + 1) }
}
for _ in 0..<150 {
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where (attr(w, "AXIdentifier") as? String) == "Progress" {
        dump(w, frame(w).origin, 0); exit(0)
    }
    usleep(100_000)
}
exit(2)
