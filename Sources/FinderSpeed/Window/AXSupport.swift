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
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
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
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success else { return nil }
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
