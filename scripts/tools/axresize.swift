// Spike: can we resize Finder's Progress window via AX? Owner: zeus.
import AppKit
import ApplicationServices
let extra = Double(CommandLine.arguments.dropFirst().first ?? "120") ?? 120
guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { exit(1) }
let app = AXUIElementCreateApplication(finder.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
for _ in 0..<100 {
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where (attr(w, "AXIdentifier") as? String) == "Progress" {
        var size = CGSize.zero; AXValueGetValue(attr(w, kAXSizeAttribute) as! AXValue, .cgSize, &size)
        var settable: DarwinBoolean = false; AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable)
        print("before \(size) settable=\(settable.boolValue)")
        var new = CGSize(width: size.width, height: size.height + extra)
        let r = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &new)!)
        usleep(300_000)
        var after = CGSize.zero; AXValueGetValue(attr(w, kAXSizeAttribute) as! AXValue, .cgSize, &after)
        print("set result=\(r.rawValue) after \(after)")
        for i in 0..<10 { usleep(500_000); var s = CGSize.zero; AXValueGetValue(attr(w, kAXSizeAttribute) as! AXValue, .cgSize, &s); print("t+\(Double(i+1)*0.5)s \(s)") }
        exit(0)
    }
    usleep(100_000)
}
print("no Progress window"); exit(2)
