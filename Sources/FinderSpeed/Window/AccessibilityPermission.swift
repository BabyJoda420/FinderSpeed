// Window/AccessibilityPermission.swift (owner: apollo)
//
// The Window module needs the Accessibility permission to see Finder's copy window
// (Spike C: AXIdentifier "Progress"). Note that TCC grants it to the *responsible* process:
// when run from a terminal, that is the terminal app, not this binary.

import AppKit
import ApplicationServices

@MainActor
public enum AccessibilityPermission {
    /// True if this process may use the Accessibility API.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its "would like to control this computer" prompt if the app is not
    /// trusted yet. Returns the current trust state (the prompt does not block, so this is
    /// usually still false right after the first call).
    @discardableResult
    public static func prompt() -> Bool {
        // Literal key instead of kAXTrustedCheckOptionPrompt (a mutable C global, not concurrency-safe).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings > Privacy & Security > Accessibility.
    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Polls until the permission is granted (there is no notification for it), then calls
    /// `granted` once on the main actor. Returns the timer so the caller can cancel it.
    @discardableResult
    public static func whenTrusted(pollInterval: TimeInterval = 1.0,
                                   _ granted: @escaping @MainActor () -> Void) -> Timer? {
        if isTrusted { granted(); return nil }
        let t = Timer(timeInterval: pollInterval, repeats: true) { timer in
            MainActor.assumeIsolated {
                if isTrusted { timer.invalidate(); granted() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
