// Spike C: detect Finder's copy-progress window.
// Build: swiftc -O -o finder-window-probe FinderWindowProbe.swift
// Run:   ./finder-window-probe [seconds=30] [intervalMs=200]
//
// Every tick it samples:
//   1. CGWindowListCopyWindowInfo for all windows owned by Finder (layer, bounds, name, alpha, onscreen)
//   2. AXUIElement tree of Finder's windows (role/subrole/title, static texts, progress indicators)
// It prints only when something changed, prefixed with elapsed milliseconds.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Private but widely used (Hammerspoon, yabai, Rectangle...): maps an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

let args = CommandLine.arguments
let duration = args.count > 1 ? Double(args[1]) ?? 30 : 30
let intervalMs = args.count > 2 ? Int(args[2]) ?? 200 : 200
let start = Date()
func ts() -> String { String(format: "[%6.0fms]", Date().timeIntervalSince(start) * 1000) }
func log(_ s: String) { print("\(ts()) \(s)"); fflush(stdout) }

// MARK: permissions
let axTrusted = AXIsProcessTrusted()
let screenCap = CGPreflightScreenCaptureAccess()
log("AXIsProcessTrusted = \(axTrusted)")
log("CGPreflightScreenCaptureAccess (Screen Recording) = \(screenCap)")

guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
    log("Finder not running"); exit(1)
}
let finderPid = finder.processIdentifier
log("Finder pid = \(finderPid)")

// MARK: CGWindowList
func cgSnapshot() -> [String] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return ["<nil>"] }
    var out: [String] = []
    for w in list {
        guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid == finderPid else { continue }
        let num = w[kCGWindowNumber as String] as? Int ?? -1
        let layer = w[kCGWindowLayer as String] as? Int ?? -999
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
        let wd = b["Width"] as? Double ?? 0, ht = b["Height"] as? Double ?? 0
        let name = w[kCGWindowName as String] as? String
        let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
        let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
        let sharing = w[kCGWindowSharingState as String] as? Int ?? -1
        let store = w[kCGWindowStoreType as String] as? Int ?? -1
        let mem = w[kCGWindowMemoryUsage as String] as? Int ?? -1
        // Skip offscreen zero-size noise unless it has a name
        if !onscreen && name == nil && (wd <= 1 || ht <= 1) { continue }
        out.append(String(format: "  cg #%d layer=%d onscreen=%@ alpha=%.2f bounds=(%.0f,%.0f %.0fx%.0f) name=%@ sharing=%d store=%d mem=%d",
                          num, layer, onscreen ? "Y" : "N", alpha, x, y, wd, ht,
                          name.map { "\"\($0)\"" } ?? "<nil>", sharing, store, mem))
    }
    return out
}

// MARK: AX helpers
func axAttr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func axStr(_ e: AXUIElement, _ a: String) -> String? {
    guard let v = axAttr(e, a) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    if CFGetTypeID(v) == AXValueGetTypeID() {
        let av = v as! AXValue
        var p = CGPoint.zero, s = CGSize.zero
        if AXValueGetValue(av, .cgPoint, &p) { return String(format: "(%.0f,%.0f)", p.x, p.y) }
        if AXValueGetValue(av, .cgSize, &s) { return String(format: "%.0fx%.0f", s.width, s.height) }
    }
    return "\(v)"
}
func axChildren(_ e: AXUIElement) -> [AXUIElement] { axAttr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

func describe(_ e: AXUIElement, depth: Int, into out: inout [String], maxDepth: Int = 12) {
    let role = axStr(e, kAXRoleAttribute) ?? "?"
    let sub = axStr(e, kAXSubroleAttribute)
    let title = axStr(e, kAXTitleAttribute)
    let value = axStr(e, kAXValueAttribute)
    let desc = axStr(e, kAXDescriptionAttribute)
    let ident = axStr(e, kAXIdentifierAttribute)
    var line = String(repeating: "  ", count: depth + 2) + role
    if let sub, !sub.isEmpty { line += "/\(sub)" }
    if let ident, !ident.isEmpty { line += " id=\(ident)" }
    if let title, !title.isEmpty { line += " title=\"\(title)\"" }
    if let desc, !desc.isEmpty { line += " desc=\"\(desc)\"" }
    if let value, !value.isEmpty { line += " value=\"\(value)\"" }
    if role == kAXProgressIndicatorRole as String {
        line += " min=\(axStr(e, kAXMinValueAttribute) ?? "?") max=\(axStr(e, kAXMaxValueAttribute) ?? "?")"
    }
    out.append(line)
    if depth < maxDepth { for c in axChildren(e) { describe(c, depth: depth + 1, into: &out, maxDepth: maxDepth) } }
}

let axApp = AXUIElementCreateApplication(finderPid)

func axSnapshot() -> [String] {
    // Try even when not trusted so we can record the error code.
    var out: [String] = []
    var err = AXError.success
    var wv: AnyObject?
    err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wv)
    guard err == .success, let wins = wv as? [AXUIElement] else { return ["  AXWindows error \(err.rawValue)"] }
    for w in wins {
        var wid: CGWindowID = 0
        let widErr = _AXUIElementGetWindow(w, &wid)
        let role = axStr(w, kAXRoleAttribute) ?? "?"
        let sub = axStr(w, kAXSubroleAttribute) ?? "?"
        let title = axStr(w, kAXTitleAttribute) ?? "<nil>"
        let pos = axStr(w, kAXPositionAttribute) ?? "?"
        let size = axStr(w, kAXSizeAttribute) ?? "?"
        let ident = axStr(w, kAXIdentifierAttribute) ?? "-"
        let modal = axStr(w, kAXModalAttribute) ?? "?"
        let minimized = axStr(w, kAXMinimizedAttribute) ?? "?"
        out.append("  ax window cgid=\(widErr == .success ? String(wid) : "err\(widErr.rawValue)") role=\(role) subrole=\(sub) title=\"\(title)\" id=\(ident) pos=\(pos) size=\(size) modal=\(modal) minimized=\(minimized)")
        // Only walk the subtree for non-browser windows (browser windows are huge).
        let isBrowser = axChildren(w).contains { axStr($0, kAXRoleAttribute) == "AXSplitGroup" }
        if !isBrowser {
            for c in axChildren(w) { describe(c, depth: 1, into: &out) }
        } else {
            out.append("    (browser window, subtree skipped)")
        }
    }
    return out
}

// MARK: loop
var lastCG: [String] = []
var lastAX: [String] = []
let deadline = start.addingTimeInterval(duration)
var tick = 0
while Date() < deadline {
    let t0 = Date()
    let cg = cgSnapshot()
    if cg != lastCG { log("CG windows (\(cg.count)) changed:\n" + cg.joined(separator: "\n")); lastCG = cg }
    let ax = axSnapshot()
    if ax != lastAX { log("AX tree changed:\n" + ax.joined(separator: "\n")); lastAX = ax }
    let cost = Date().timeIntervalSince(t0) * 1000
    if tick % 25 == 0 { log(String(format: "tick %d (sample cost %.1fms)", tick, cost)) }
    tick += 1
    usleep(useconds_t(max(0, Double(intervalMs) - cost) * 1000))
}
log("done")
