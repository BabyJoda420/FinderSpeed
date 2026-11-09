# Phase 2 report: the Window module (apollo)

**Does it work? Yes.** `swift build` compiles with no errors and no warnings. I tested the module against a real 10 GB Finder folder copy using a throwaway driver in `spikes/window/driver/`.

## What I built

All of it is in `Sources/FinderSpeed/Window/`.

| File | Contents |
|---|---|
| `FinderProgressWindowObserver.swift` | Finds and follows Finder's copy window (`AXIdentifier == "Progress"`) and parses its rows |
| `FinderDestinationHints.swift` | Asks Finder for candidate destination folders and feeds them to `TransferMonitor.noteFinderDestination` |
| `SpeedPanelController.swift` | The panel attached under Finder's window, hosting SwiftUI content from App/UI |
| `AccessibilityPermission.swift` | Checks and requests the Accessibility permission |
| `AXSupport.swift` | Internal helpers: AX attribute reads, `_AXUIElementGetWindow`, coordinate conversion, CGWindowList lookups |

All public types are `@MainActor`.

## Public API

### `FinderProgressWindowObserver`

```swift
@MainActor public final class FinderProgressWindowObserver {
    public init()
    public func start()      // attach now, or once trusted and Finder runs; re-attaches on Finder relaunch
    public func stop()
    public func refresh()    // re-read the frame and rows now

    @discardableResult
    public func addHandler(_ handler: @escaping (Event, WindowInfo?) -> Void) -> HandlerToken   // @MainActor
    public func removeHandler(_ token: HandlerToken)

    public private(set) var window: WindowInfo?   // nil when Finder shows no progress window
    public private(set) var isAttached: Bool
    public var debugLogging: Bool

    public struct WindowInfo: Equatable, Sendable {
        public let windowID: CGWindowID?   // from _AXUIElementGetWindow; falls back to matching the frame in CGWindowList
        public let frame: NSRect           // AppKit coordinates (origin bottom-left of the primary screen)
        public let axFrame: CGRect         // AX/CG coordinates (origin top-left)
        public let rows: [Row]
        public let isMinimized: Bool
        public var rowCount: Int
    }
    public struct Row: Equatable, Sendable {
        public let index: Int                    // identity = position, top to bottom
        public let title: String                 // "Copying 6 items to “apollo”" (localized)
        public let status: String                // "947.9 MB of 2.15 GB – About 5 seconds" (localized)
        public let fraction: Double?             // progress bar 0...1 (folder copies stick at ~0.9999)
        public let destinationName: String?      // last quoted name in the title: "apollo"
        public let statusBytesCompleted: Int64?  // best-effort parse of the copied amount (decimal units)
    }
    public enum Event { case appeared, moved, resized, rowsChanged, orderingMayHaveChanged, minimizedChanged, disappeared }
}
```

**AX notifications it registers:**
- On the Finder app element: `AXWindowCreated`, `AXValueChanged` (fires for the status texts at about 2 Hz), `AXFocusedWindowChanged` and `AXMainWindowChanged`.
- On the tracked window: `AXMoved`, `AXResized`, `AXUIElementDestroyed`, `AXWindowMiniaturized` and `AXWindowDeminiaturized`.
- All AX calls into Finder use a 0.5 s messaging timeout.

**How rows are read.** Rows are matched by element order, not by title. Each `AXProgressIndicator` starts a new row. The row's title is the last static text before the indicator, and its status is the first static text after it.

**Startup and restarts:**
- At startup the observer scans Finder's existing windows.
- It follows Finder through `NSWorkspace` launch and terminate notifications, re-attaching about 0.5 s after Finder launches and retrying while AX isn't ready.
- If Accessibility is not granted yet, it polls once per second and attaches as soon as the permission arrives.

**Safety tick.** A 1 s timer re-reads the tracked window (or rescans if none is tracked) and re-attaches if Finder's pid changed. Each tick also emits `orderingMayHaveChanged`. Frontmost-app, hide and unhide notifications emit `orderingMayHaveChanged` as well.

### `FinderDestinationHints`

```swift
@MainActor public final class FinderDestinationHints {
    public init(noteDestination: @escaping (URL) -> Void)       // @MainActor
    public convenience init(monitor: TransferMonitor)            // calls monitor.noteFinderDestination(_:)
    public func attach(to observer: FinderProgressWindowObserver)
    public func requestNow()
    public func destination(for row: FinderProgressWindowObserver.Row) -> URL?
    public private(set) var resolvedDestinations: [String: URL]  // row destination name -> folder
    public var onResolve: ((String, URL) -> Void)?
    public var debugLogging: Bool
}
```

**When it asks Finder:**
- When the progress window appears.
- On `rowsChanged`, while a row's destination name is still unresolved. These follow-up queries are rate limited to at most one per 1.5 s and 3 attempts per name.

**How it asks.** NSAppleScript runs on a private serial queue, never the main thread, and asks Finder for the `insertion location` plus the `target` of every Finder window. It calls `noteDestination` for every candidate folder.

**How it resolves a row's destination name**, in this order of preference:
1. A candidate folder with that name.
2. A direct subfolder of a candidate (a drop onto a folder inside a window).
3. A mounted volume with that name.
4. A top-level folder on a mounted volume.
5. A standard user folder.

The resolved folder is also passed to `noteDestination`.

**If automation is denied** (error -1743), it stops asking.

### `SpeedPanelController`

```swift
@MainActor public final class SpeedPanelController {
    public init<Content: View>(content: Content)
    public convenience init(rootView: AnyView)
    public func setContent<Content: View>(_ content: Content)
    public func attach(to observer: FinderProgressWindowObserver)
    public func detach()

    public var gap: CGFloat                    // default 0 (flush)
    public var bottomCornerRadius: CGFloat     // default 12
    public var fadeDuration: TimeInterval      // default 0.2
    public var resizeDuration: TimeInterval    // default 0.2, for height changes of the content
    public var flipsAboveWhenOffscreen: Bool   // default true
    public var debugLogging: Bool
    public private(set) var isShown: Bool
    public var windowNumber: Int
    public var frame: NSRect
}
```

**The window itself:**
- An `NSPanel` subclass, `[.borderless, .nonactivatingPanel]`, that never becomes key or main.
- `level = .normal`, `hidesOnDeactivate = false`, `collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]`.

**Placement and ordering:**
- Same x and width as Finder's window, with its top edge at Finder's bottom edge minus `gap`.
- Height is the hosting view's `fittingSize` at that width. SwiftUI size changes (`invalidateIntrinsicContentSize`) trigger an animated relayout.
- Ordering is `order(.above, relativeTo: finderWID)`. It is skipped when `CGWindowList(.optionOnScreenAboveWindow)` already shows the panel directly above Finder's window.

**Visibility:**
- Shown only while Finder's window exists, is on screen (`kCGWindowIsOnscreen`, so another Space hides it), is not minimized, and Finder is not hidden.
- Visibility is re-checked when the active Space changes.
- Showing and hiding fade the alpha. After the fade-out the panel is ordered out.

**Content:** the background is an `NSVisualEffectView` (`.windowBackground`, behind-window blending) with rounded bottom corners. The SwiftUI host returns `acceptsFirstMouse = true`, so a toggle button works on the first click without activating the app.

### `AccessibilityPermission`

```swift
@MainActor public enum AccessibilityPermission {
    public static var isTrusted: Bool                    // AXIsProcessTrusted()
    @discardableResult public static func prompt() -> Bool   // AXIsProcessTrustedWithOptions(prompt: true)
    public static func openSystemSettings()              // Privacy & Security > Accessibility
    @discardableResult public static func whenTrusted(pollInterval: TimeInterval = 1.0,
                                                      _ granted: @escaping () -> Void) -> Timer?
}
```

### Typical wiring (for App/main.swift)

```swift
let monitor = TransferMonitor(); monitor.start()
let observer = FinderProgressWindowObserver()
let hints = FinderDestinationHints(monitor: monitor); hints.attach(to: observer)
let panel = SpeedPanelController(content: SomeThorView(monitor: monitor))
panel.attach(to: observer)
if !AccessibilityPermission.isTrusted { AccessibilityPermission.prompt() }
observer.start()   // waits for the permission by itself
```

## Test evidence

The source was a folder with 5 APFS clones of `big_2g.bin` (10.74 GB). I used Finder's `duplicate` to copy it to `/Volumes/FinderSpeedTest/apollo`. Log: `spikes/window/logs/phase2_driver_10g.log`.

- **Detection:** `appeared: id=5843 frame=(74.0, 493.0, 404.0, 88.0) rows=1`. That is about 3 s after the copy started, which matches Spike C.
- **Attachment and ordering:** the panel frame was `(74.0, 445.0, 404.0, 48.0)`. The driver checked `flushUnderFinder=true`, and the on-screen window list put the panel at index 3 and Finder's window at index 4 (front = 0), so the panel is directly in front of Finder's window.
- **Moves:** the driver moved Finder's window +60 px through AX and then back. `event moved frame=(134.0, ...)` was followed by `panel frame (134.0, 445.0, 404.0, 48.0)`, then `moved (74.0, ...)` by `panel (74.0, ...)`. The panel followed in the same millisecond each time.
- **Content height:** expanding the fake graph changed the fitting height from 48 to 132, with the panel frame becoming `(74, 361, 404, 132)` and the top edge staying attached. Collapsing it went back to 48.
- **Rows:** `row 0 dest=apollo status="7.70 GB of 7.7 GB – About 5 seconds" bytes=7700000000`. The status updates at about 2 Hz.
- **Hints:**
  - The AppleScript returned `["/Users/mauriziolol/Desktop/"]` in 1055 ms on the first call, which includes compiling the script.
  - `resolved “apollo” -> /Volumes/FinderSpeedTest/apollo`, found by the top-level-folder-on-a-volume rule.
  - After that the Engine reported `transfer testsrc -> /Volumes/FinderSpeedTest/apollo`.
- **Disappearance:** `[window] disappeared` was followed by `[panel] hide`, about 0.1 s after the last update.
- **Bug found and fixed:** the first test run crashed with exit code 133, a Swift trap. `CGWindowID(panel.windowNumber)` was called while `windowNumber` was still -1, before the panel had been ordered in for the first time. The code now compares the numbers as `Int`, and the CG window-number conversion uses `CGWindowID(exactly:)`.

### Engine finding for Athena: folder copies report the wrong byte count

During the driver run the transfer stayed at `2147680256/2147680256 0 MB/s samples=0`. To rule out the late subscription, I re-ran the copy with `FinderSpeed --engine-debug /Volumes/FinderSpeedTest/apollo`, subscribed before the copy started. Log: `logs/phase2_engine_debug_folder_copy.log`.

```
[ 3.0s] copying "testsrc"  377.5 MB/2.15 GB (17.6%)  speed=755 MB/s
[ 6.0s] copying "testsrc"  2.15 GB/2.15 GB (100.0%)  speed=668.9 MB/s
[ 8.0s] ...               2.15 GB/2.15 GB (100.0%)  speed=118.2 MB/s raw=Zero KB/s
[16.0s] FINISHED "testsrc" 2.15 GB/2.15 GB  avg=156.5 MB/s
```

So Finder's NSProgress for a folder copy stops at the **first file's size** (2.15 GB), while 10.74 GB were actually copied. Finder's own window text keeps counting ("10.15 GB of 10.15 GB"). The window module exposes that count as `Row.statusBytesCompleted`, so the Engine could use it as a fallback speed source for folder copies. That needs a decision from Athena and Zeus.

## Permissions

- **Accessibility:** required by the observer, and so by the panel. The grant goes to the responsible process: run from a terminal, that is the terminal app.
- **Automation (Finder):** used by `FinderDestinationHints`. The bundled app needs `NSAppleEventsUsageDescription` in its Info.plist.
- **Screen Recording:** not needed.

## Files

- `Sources/FinderSpeed/Window/AXSupport.swift`, `AccessibilityPermission.swift`, `FinderProgressWindowObserver.swift`, `FinderDestinationHints.swift`, `SpeedPanelController.swift`
- `spikes/window/driver/main.swift`, `build.sh`, `window-driver`: the throwaway driver. It is not part of the package. It compiles the Window and Engine sources with `swiftc`.
- `spikes/window/logs/phase2_driver_10g.log`, `phase2_engine_debug_folder_copy.log`
- I removed the test clones (`testsrc/`) again, and `/Volumes/FinderSpeedTest/apollo` is empty. To recreate them: `mkdir testsrc; for i in 1 2 3 4 5; do cp -c ../../testdata/big_2g.bin testsrc/big_$i.bin; done` in `spikes/window/`.

## Open questions

1. **Not tested yet:**
   - **Finder relaunch.** `killall Finder` would break the other agents' running Finder copies, so I didn't run it. The re-attach code path exists but has not been exercised.
   - **AXMoved during a real drag.** How often does it fire while the user drags the window, and is it throttled? I only moved the window programmatically through AX.
   - **Spaces and full screen.** The panel should hide when Finder's window goes off screen, and show again on return. Not verified.
   - **Multiple displays.** The coordinate conversion uses the primary screen's height, which is correct in principle, but untested with more than one screen.
2. **What should the panel do if Finder's window id can't be found?** If neither `_AXUIElementGetWindow` nor the CGWindowList frame match finds it, the panel currently stays **hidden**, instead of being shown unordered, where it could float above other apps' windows. Is that the behavior you want?
3. **Possible duplicate transfers in the Engine.** In the first driver run, Athena's `athena-tcc-probe.bin` showed up as **three separate transfers**, one each under `~/Desktop`, `~/Downloads` and `~/Documents`, all with the same bytes (130000000/1000000000). That may be a duplicate-subscription or folder-fallback issue in the Engine. It's only an observation; I didn't investigate, since it's not my module.
