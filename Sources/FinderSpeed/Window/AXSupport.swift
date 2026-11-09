// Window/AXSupport.swift (owner: apollo)
// Small internal helpers around the Accessibility C API, shared by the Window module.

import AppKit
import ApplicationServices

/// Private but long-stable SPI (used by Hammerspoon, yabai, Rectangle, ...): AX window -> CGWindowID.
/// Spike C verified it on macOS 27 (cgid 5819 matched CGWindowList).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return copy(e, name, &v) == .success ? v : nil
    }

    /// AXUIElementCopyAttributeValue, timed: slow calls and real failures go to the diagnostic log
    /// (BUG-001: a busy Finder answers slowly or with kAXErrorCannotComplete).
    /// Test hook (BUG-001): FINDERSPEED_SIMULATE_AX="delay=0.6,fail=0.3" makes every AX read sleep
    /// `delay` seconds and fail with kAXErrorCannotComplete with probability `fail`, like a busy Finder.
    static let simulation: (delay: Double, fail: Double)? = {
        guard let spec = ProcessInfo.processInfo.environment["FINDERSPEED_SIMULATE_AX"] else { return nil }
        var d = 0.0, f = 0.0
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=")
            guard kv.count == 2, let v = Double(kv[1]) else { continue }
            if kv[0] == "delay" { d = v } else if kv[0] == "fail" { f = v }
        }
        return (d, f)
    }()

    @discardableResult
    static func copy(_ e: AXUIElement, _ name: String, _ v: inout AnyObject?) -> AXError {
        if let sim = simulation {
            if sim.delay > 0 { usleep(useconds_t(sim.delay * 1_000_000)) }
            if Double.random(in: 0..<1) < sim.fail {
                WindowDiagnostics.log("ax", "\(name) -> -25204 (simulated)")
                return .cannotComplete
            }
        }
        guard WindowDiagnostics.enabled else { return AXUIElementCopyAttributeValue(e, name as CFString, &v) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let err = AXUIElementCopyAttributeValue(e, name as CFString, &v)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let benign: Set<AXError> = [.success, .noValue, .attributeUnsupported, .notImplemented]
        if ms > 50 || !benign.contains(err) {
            WindowDiagnostics.log("ax", String(format: "%@ -> %d in %.0f ms", name, err.rawValue, ms))
        }
        return err
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? {
        attribute(e, name) as? String
    }

    static func double(_ e: AXUIElement, _ name: String) -> Double? {
        (attribute(e, name) as? NSNumber)?.doubleValue
    }

    static func bool(_ e: AXUIElement, _ name: String) -> Bool? {
        (attribute(e, name) as? NSNumber)?.boolValue
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement]? {
        var v: AnyObject?
        guard copy(app, kAXWindowsAttribute, &v) == .success else { return nil }
        return v as? [AXUIElement] ?? []
    }

    /// The window frame in AX/CG global coordinates (origin top-left of the main display).
    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv = attribute(e, kAXPositionAttribute), let sv = attribute(e, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func windowID(_ e: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(e, &wid) == .success && wid != 0 ? wid : nil
    }

    /// Depth-first descendants in document order, up to `maxDepth`.
    static func flattenedDescendants(_ e: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            for c in children(el) {
                out.append(c)
                if depth < maxDepth { walk(c, depth + 1) }
            }
        }
        walk(e, 1)
        return out
    }
}

enum ScreenGeometry {
    /// Converts a rect in global top-left coordinates (AX, CGWindowList) to AppKit's global
    /// bottom-left coordinates. Both systems are anchored to the primary (menu bar) screen.
    static func appKitRect(fromTopLeft r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }
}

enum FinderApp {
    static let bundleID = "com.apple.finder"
    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }
}

enum CGWindows {
    /// On-screen windows, front to back.
    static func onScreen() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    static func bounds(_ info: [String: Any]) -> CGRect? {
        guard let d = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: d as CFDictionary)
    }

    /// Fallback for `_AXUIElementGetWindow`: the Finder window whose bounds equal `frame`.
    static func finderWindowID(matching frame: CGRect, pid: pid_t) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = bounds(w),
                  abs(b.minX - frame.minX) <= 1, abs(b.minY - frame.minY) <= 1,
                  abs(b.width - frame.width) <= 1, abs(b.height - frame.height) <= 1,
                  let n = (w[kCGWindowNumber as String] as? Int).flatMap(CGWindowID.init(exactly:)) else { continue }
            return n
        }
        return nil
    }
}
