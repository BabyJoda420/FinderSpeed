// Spike C, part 2: event-driven tracking of Finder's copy window via AXObserver.
// Build: swiftc -O -o finder-ax-observe FinderAXObserve.swift
// Run:   ./finder-ax-observe [seconds=30]
// Needs Accessibility permission. Prints notifications and, on every value change
// inside the "Progress" window, the parsed "<copied> of <total>" text plus a derived speed.

import AppKit
import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 30 : 30
let start = Date()
func log(_ s: String) { print(String(format: "[%6.0fms] ", Date().timeIntervalSince(start) * 1000) + s); fflush(stdout) }

guard AXIsProcessTrusted() else { log("AXIsProcessTrusted = false, need Accessibility"); exit(1) }
guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { exit(1) }
let pid = finder.processIdentifier
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func frame(_ e: AXUIElement) -> String {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return String(format: "(%.0f,%.0f %.0fx%.0f)", p.x, p.y, s.width, s.height)
}
func isProgressWindow(_ w: AXUIElement) -> Bool { str(w, kAXIdentifierAttribute) == "Progress" }

// Parse "1.52 GB of 2.15 GB – About 5 seconds" -> bytes copied (decimal units, as Finder uses).
func parseBytes(_ s: String) -> Double? {
    let units: [String: Double] = ["bytes": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]
    let scanner = s.split(separator: " ")
    guard scanner.count >= 2, let n = Double(scanner[0].replacingOccurrences(of: ",", with: "")),
          let u = units[String(scanner[1])] else { return nil }
    return n * u
}

var lastBytes: [String: (Double, Date)] = [:]   // keyed by row title
func dumpRows(_ w: AXUIElement) {
    guard let scroll = children(w).first(where: { str($0, kAXRoleAttribute) == "AXScrollArea" }) else { return }
    var title = "?"
    for c in children(scroll) {
        let role = str(c, kAXRoleAttribute)
        let ident = str(c, kAXIdentifierAttribute) ?? ""
        let value = attr(c, kAXValueAttribute)
        if role == "AXStaticText", ident == "_NS:59" { title = value as? String ?? "?" }
        if role == "AXStaticText", ident == "_NS:89", let text = value as? String {
            var speed = ""
            if let b = parseBytes(text) {
                let now = Date()
                if let (pb, pt) = lastBytes[title], b > pb { speed = String(format: "  -> %.0f MB/s", (b - pb) / now.timeIntervalSince(pt) / 1e6) }
                if lastBytes[title] == nil || b > lastBytes[title]!.0 { lastBytes[title] = (b, now) }
            }
            log("    row \"\(title)\": \"\(text)\"\(speed)")
        }
    }
}

var observed = Set<CGWindowID>()
var gObserver: AXObserver? = nil
let observerCallback: AXObserverCallback = { _, element, notification, _ in
    let n = notification as String
    var wid: CGWindowID = 0
    _ = _AXUIElementGetWindow(element, &wid)
    let role = str(element, kAXRoleAttribute) ?? "?"
    let ident = str(element, kAXIdentifierAttribute) ?? "-"
    switch n {
    case kAXWindowCreatedNotification as String:
        log("WindowCreated cgid=\(wid) role=\(role) id=\(ident) title=\(str(element, kAXTitleAttribute) ?? "nil") frame=\(frame(element))")
        if isProgressWindow(element) { watch(element) }
    case kAXValueChangedNotification as String:
        // element is the static text / progress bar; find its window
        if let w = attr(element, kAXWindowAttribute), isProgressWindow(w as! AXUIElement), role == "AXStaticText",
           ident == "_NS:89" { dumpRows(w as! AXUIElement) }
    default:
        log("\(n) cgid=\(wid) role=\(role) id=\(ident) frame=\(role == "AXWindow" ? frame(element) : "-")")
    }
}

var observer: AXObserver?
guard AXObserverCreate(pid, observerCallback, &observer) == .success, observer != nil else { log("AXObserverCreate failed"); exit(1) }
gObserver = observer
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(gObserver!), .defaultMode)

func add(_ e: AXUIElement, _ n: String) {
    let err = AXObserverAddNotification(gObserver!, e, n as CFString, nil)
    if err != .success && err != .notificationAlreadyRegistered { log("  add \(n) err=\(err.rawValue)") }
}
func watch(_ w: AXUIElement) {
    var wid: CGWindowID = 0; _ = _AXUIElementGetWindow(w, &wid)
    guard !observed.contains(wid) else { return }
    observed.insert(wid)
    log("  watching progress window cgid=\(wid) frame=\(frame(w))")
    for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] { add(w, n as String) }
    dumpRows(w)
    if CommandLine.arguments.contains("--nudge") {
        // Test only: move the window 40px right, then back, to verify kAXMovedNotification fires.
        var p = CGPoint.zero
        if let v = attr(w, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        for (delay, dx) in [(1.0, 40.0), (2.0, 0.0)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var np = CGPoint(x: p.x + dx, y: p.y)
                let err = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &np)!)
                log("  nudge to x=\(np.x) err=\(err.rawValue)")
            }
        }
    }
}

// App-level notifications. ValueChanged registered on the app element catches all descendants.
for n in [kAXWindowCreatedNotification, kAXValueChangedNotification, kAXFocusedWindowChangedNotification] { add(app, n as String) }
// Pick up a progress window that already exists.
for w in attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] where isProgressWindow(w) { watch(w) }

log("observing Finder pid \(pid) for \(duration)s")
CFRunLoopRunInMode(.defaultMode, duration, false)
log("done")
