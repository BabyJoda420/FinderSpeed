// Window/FinderProgressWindowObserver.swift (owner: apollo)
//
// Finds and follows Finder's copy-progress window through the Accessibility API.
// Facts from Spike C (spikes/window/REPORT.md):
//  * The window is AXWindow/AXStandardWindow, AXIdentifier "Progress" (not localized), title "Copy".
//    Finder browser windows are AXDialog with AXIdentifier "FinderWindow".
//  * ONE window holds all concurrent operations, one row per operation. Each row is, in order:
//    AXStaticText (title, "Copying 6 items to “apollo”"), AXProgressIndicator (0...1),
//    AXButton ("stop progress"), AXStaticText (status, "1.52 GB of 2.15 GB – About 5 seconds").
//    Row titles change during a copy ("6 items" -> "5 items" ...), so rows are matched by order.
//  * The window appears ~3 s after the copy starts. Copies shorter than that never get a window.
//  * AXWindowCreated, AXMoved, AXUIElementDestroyed fire; AXValueChanged (registered on the app
//    element) fires for the status texts at ~2 Hz.
//
// Everything runs on the main thread. AX calls into Finder use a 0.5 s messaging timeout.

import AppKit
import ApplicationServices

@MainActor
public final class FinderProgressWindowObserver {

    // MARK: Public types

    public struct Row: Equatable, Sendable {
        /// Position in the window, top to bottom. This is the row's identity.
        public let index: Int
        /// E.g. "Copying 6 items to “apollo”" or "Copying “big_2g.bin” to “athena”". Localized.
        public let title: String
        /// E.g. "947.9 MB of 2.15 GB – About 5 seconds". Localized. Empty while not shown.
        public let status: String
        /// The progress bar value, 0...1. Nil if unreadable. Folder copies sit at ~0.9999 (Finder bug).
        public let fraction: Double?
        /// The destination folder's display name: the last quoted name in `title` ("apollo").
        public let destinationName: String?
        /// Best-effort parse of the copied amount at the start of `status` (decimal units).
        public let statusBytesCompleted: Int64?
        /// Best-effort parse of the "of Y" total in `status` (decimal units). Nil if not shown or
        /// unparseable. Note: for folder copies Finder's total can trail the copied count ("X of X").
        public let statusBytesTotal: Int64?
    }

    public struct WindowInfo: Equatable, Sendable {
        /// The window server ID of Finder's window (nil if neither lookup worked).
        public let windowID: CGWindowID?
        /// Frame in AppKit global coordinates (origin bottom-left of the primary screen).
        public let frame: NSRect
        /// Frame in AX / CGWindowList coordinates (origin top-left of the primary screen).
        public let axFrame: CGRect
        public let rows: [Row]
        public let isMinimized: Bool
        /// True when Finder is the active app and this window is its main window, i.e. the window
        /// server draws it with the active (larger) shadow.
        public let isActive: Bool
        public var rowCount: Int { rows.count }
    }

    public enum Event: Equatable, Sendable {
        case appeared
        case moved
        case resized
        case rowsChanged
        /// Finder's focused window or the frontmost app changed: the panel should re-check its
        /// ordering relative to Finder's window.
        case orderingMayHaveChanged
        case minimizedChanged
        /// `WindowInfo.isActive` changed (Finder activated/deactivated, or the window became main).
        case activationChanged
        case disappeared
    }

    public typealias Handler = @MainActor (Event, WindowInfo?) -> Void
    public struct HandlerToken: Hashable, Sendable { fileprivate let id: Int }

    // MARK: Public state

    /// The tracked progress window, nil when Finder shows none.
    public private(set) var window: WindowInfo?
    /// True while an AXObserver is attached to a running Finder.
    public private(set) var isAttached = false
    /// Verbose logging to stdout (for the spike driver).
    public var debugLogging = false

    public init() {}

    @discardableResult
    public func addHandler(_ handler: @escaping Handler) -> HandlerToken {
        nextHandlerID += 1
        let t = HandlerToken(id: nextHandlerID)
        handlers.append((t, handler))
        return t
    }

    public func removeHandler(_ token: HandlerToken) {
        handlers.removeAll { $0.0 == token }
    }

    /// Attaches to Finder (now, or once the Accessibility permission is granted and Finder runs)
    /// and keeps re-attaching when Finder relaunches. Calling it again has no extra effect.
    public func start() {
        guard !started else { return }
        started = true

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                 object: nil, queue: .main) { [weak self] note in
            guard Self.isFinder(note) else { return }
            MainActor.assumeIsolated { self?.scheduleAttach(after: 0.5) }
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                 object: nil, queue: .main) { [weak self] note in
            guard Self.isFinder(note) else { return }
            MainActor.assumeIsolated { self?.detach() }
        })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusMayHaveChanged() }
            })
        }

        // Safety net: re-read the window state every second (notifications can be missed, e.g.
        // when Finder was busy past the messaging timeout) and re-attach if needed.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.safetyTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        safetyTimer = t

        if AccessibilityPermission.isTrusted {
            attach()
        } else {
            log("not trusted, waiting for Accessibility permission")
            trustTimer = AccessibilityPermission.whenTrusted { [weak self] in self?.attach() }
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()
        safetyTimer?.invalidate(); safetyTimer = nil
        trustTimer?.invalidate(); trustTimer = nil
        detach()
    }

    /// Re-reads the frame and rows now.
    public func refresh() {
        if windowElement == nil { scanForProgressWindow() } else { reread(trigger: nil) }
    }

    // MARK: Private state

    private var started = false
    private var handlers: [(HandlerToken, Handler)] = []
    private var nextHandlerID = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var safetyTimer: Timer?
    private var trustTimer: Timer?
    private var attachRetryScheduled = false

    private var finderPid: pid_t = 0
    private var appElement: AXUIElement?
    private var axObserver: AXObserver?
    private var windowElement: AXUIElement?
    private var rowRefreshPending = false

    private static let progressIdentifier = "Progress"
    private static let messagingTimeout: Float = 0.5

    nonisolated private static func isFinder(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == FinderApp.bundleID
    }

    private func log(_ s: @autoclosure () -> String) {
        if debugLogging { print("[window] \(s())"); fflush(stdout) }
    }

    private func emit(_ event: Event) {
        for (_, h) in handlers { h(event, window) }
    }

    // MARK: Attach / detach

    private func scheduleAttach(after delay: TimeInterval) {
        guard started, !attachRetryScheduled else { return }
        attachRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.attachRetryScheduled = false
                self.attach()
            }
        }
    }

    private func attach() {
        guard started, AccessibilityPermission.isTrusted else { return }
        guard let finder = FinderApp.running else { log("Finder not running"); return }
        if isAttached && finder.processIdentifier == finderPid { return }
        detach()

        let pid = finder.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)

        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else {
            log("AXObserverCreate failed, retrying"); scheduleAttach(after: 1); return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var ok = true
        for n in [kAXWindowCreatedNotification, kAXValueChangedNotification,
                  kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            let err = AXObserverAddNotification(obs, app, n as CFString, refcon)
            if err != .success && err != .notificationAlreadyRegistered {
                log("add \(n) on app failed: \(err.rawValue)")
                if n == kAXWindowCreatedNotification { ok = false }
            }
        }
        guard ok else {
            // Typically kAXErrorCannotComplete right after Finder launches.
            scheduleAttach(after: 1); return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)

        finderPid = pid
        appElement = app
        axObserver = obs
        isAttached = true
        log("attached to Finder pid \(pid)")
        scanForProgressWindow()
    }

    private func detach() {
        if windowElement != nil { untrackWindow() }
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        if isAttached { log("detached from Finder pid \(finderPid)") }
        axObserver = nil
        appElement = nil
        finderPid = 0
        isAttached = false
    }

    // MARK: Window tracking

    private func isProgressWindow(_ e: AXUIElement) -> Bool {
        AX.string(e, kAXIdentifierAttribute) == Self.progressIdentifier
    }

    private func scanForProgressWindow() {
        guard let app = appElement, windowElement == nil else { return }
        guard let wins = AX.windows(app) else { return }
        if let w = wins.first(where: isProgressWindow) { track(w) }
    }

    private func track(_ w: AXUIElement) {
        guard let obs = axObserver else { return }
        if let cur = windowElement {
            if CFEqual(cur, w) { return }
            untrackWindow()
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            let err = AXObserverAddNotification(obs, w, n as CFString, refcon)
            if err != .success && err != .notificationAlreadyRegistered { log("add \(n) on window failed: \(err.rawValue)") }
        }
        windowElement = w
        guard let info = readInfo(w) else { untrackWindow(); return }
        window = info
        log("appeared: id=\(info.windowID.map(String.init) ?? "nil") frame=\(info.frame) rows=\(info.rowCount)")
        emit(.appeared)
    }

    private func untrackWindow() {
        if let obs = axObserver, let w = windowElement {
            for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                AXObserverRemoveNotification(obs, w, n as CFString)
            }
        }
        windowElement = nil
        rowRefreshPending = false
        if window != nil {
            window = nil
            log("disappeared")
            emit(.disappeared)
        }
    }

    /// Re-reads the tracked window and emits events for what changed.
    private func reread(trigger: Event?) {
        guard let w = windowElement else { return }
        guard let info = readInfo(w) else {
            // The element is gone (Destroyed can be missed). Look for a replacement.
            untrackWindow()
            scanForProgressWindow()
            return
        }
        let old = window
        window = info
        guard let old else { emit(.appeared); return }
        var events: [Event] = []
        if old.axFrame.origin != info.axFrame.origin { events.append(.moved) }
        if old.axFrame.size != info.axFrame.size { events.append(.resized) }
        if old.isMinimized != info.isMinimized { events.append(.minimizedChanged) }
        if old.isActive != info.isActive { events.append(.activationChanged) }
        if old.rows != info.rows { events.append(.rowsChanged) }
        if events.isEmpty, let trigger, trigger == .orderingMayHaveChanged { events.append(trigger) }
        if old.windowID != info.windowID && !events.contains(.orderingMayHaveChanged) { events.append(.orderingMayHaveChanged) }
        for e in events { emit(e) }
    }

    private func readInfo(_ w: AXUIElement) -> WindowInfo? {
        var role: AnyObject?
        let err = AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &role)
        if err == .invalidUIElement { return nil }
        guard let axFrame = AX.frame(w) else { return err == .success ? window : nil }
        let wid = AX.windowID(w) ?? window?.windowID ?? CGWindows.finderWindowID(matching: axFrame, pid: finderPid)
        return WindowInfo(
            windowID: wid,
            frame: ScreenGeometry.appKitRect(fromTopLeft: axFrame),
            axFrame: axFrame,
            rows: readRows(w),
            isMinimized: AX.bool(w, kAXMinimizedAttribute) ?? false,
            isActive: NSWorkspace.shared.frontmostApplication?.processIdentifier == finderPid
                && (AX.bool(w, kAXMainAttribute) ?? false)
        )
    }

    /// Rows by element order: each AXProgressIndicator starts a row; its title is the last
    /// static text before it, its status the first static text after it.
    private func readRows(_ w: AXUIElement) -> [Row] {
        let container = AX.children(w).first { AX.string($0, kAXRoleAttribute) == kAXScrollAreaRole as String } ?? w
        let elements = AX.flattenedDescendants(container, maxDepth: 4)
        var rows: [(title: String, status: String?, fraction: Double?)] = []
        var pendingText: String?
        for e in elements {
            switch AX.string(e, kAXRoleAttribute) {
            case kAXStaticTextRole?:
                let text = AX.string(e, kAXValueAttribute) ?? ""
                if let last = rows.indices.last, rows[last].status == nil {
                    rows[last].status = text
                } else {
                    pendingText = text
                }
            case kAXProgressIndicatorRole?:
                rows.append((pendingText ?? "", nil, AX.double(e, kAXValueAttribute)))
                pendingText = nil
            default:
                break
            }
        }
        return rows.enumerated().map { i, r in
            Row(index: i, title: r.title, status: r.status ?? "", fraction: r.fraction,
                destinationName: ProgressText.destinationName(in: r.title),
                statusBytesCompleted: ProgressText.bytesCompleted(in: r.status ?? ""),
                statusBytesTotal: ProgressText.bytesTotal(in: r.status ?? ""))
        }
    }

    private func scheduleRowRefresh() {
        guard !rowRefreshPending else { return }
        rowRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rowRefreshPending else { return }
                self.rowRefreshPending = false
                self.reread(trigger: nil)
            }
        }
    }

    private func emitOrderingHint() {
        guard window != nil else { return }
        emit(.orderingMayHaveChanged)
    }

    /// Activation or focus changed somewhere: re-read (isActive may have changed) and let the panel
    /// re-check its ordering.
    private func focusMayHaveChanged() {
        guard windowElement != nil else { return }
        reread(trigger: .orderingMayHaveChanged)
    }

    private func safetyTick() {
        guard started else { return }
        if !isAttached {
            if AccessibilityPermission.isTrusted, FinderApp.running != nil { attach() }
            return
        }
        if let f = FinderApp.running, f.processIdentifier != finderPid { attach(); return }
        if windowElement == nil { scanForProgressWindow() } else { reread(trigger: .orderingMayHaveChanged) }
    }

    // MARK: AX callback

    fileprivate func handle(notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            if isProgressWindow(element) { track(element) }
        case kAXValueChangedNotification:
            guard let wv = AX.attribute(element, kAXWindowAttribute), CFGetTypeID(wv) == AXUIElementGetTypeID() else { return }
            let win = wv as! AXUIElement
            if let cur = windowElement, CFEqual(cur, win) {
                scheduleRowRefresh()
            } else if windowElement == nil, isProgressWindow(win) {
                track(win)   // missed the creation
            }
        case kAXMovedNotification, kAXResizedNotification,
             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            reread(trigger: nil)
        case kAXUIElementDestroyedNotification:
            if let cur = windowElement, CFEqual(cur, element) || readInfo(cur) == nil {
                untrackWindow()
                scanForProgressWindow()
            }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            if windowElement == nil, isProgressWindow(element) { track(element) }
            focusMayHaveChanged()
        default:
            break
        }
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                        _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let name = notification as String
    // The run loop source is on the main run loop.
    MainActor.assumeIsolated {
        let me = Unmanaged<FinderProgressWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
        me.handle(notification: name, element: element)
    }
}

/// Parsing of the (localized) row texts. Best effort; never required for tracking.
enum ProgressText {
    /// The last quoted name in a row title: "Copying 6 items to “apollo”" -> "apollo".
    static func destinationName(in title: String) -> String? {
        let pattern = #"[“"«„‘‚‹「]([^”"»“’‘›」]+)[”"»“’‘›」]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = title as NSString
        guard let m = re.matches(in: title, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// "1.52 GB of 2.15 GB – ..." -> 1_520_000_000: the amount at the very start of the status.
    static func bytesCompleted(in status: String) -> Int64? {
        let t = tokens(status)
        return t.count >= 2 ? amount(t[0], t[1]) : nil
    }

    /// "1.52 GB of 2.15 GB – ..." -> 2_150_000_000: the first amount after the copied amount,
    /// whatever the localized separator word is ("of", "von", "sur", "de", ...). Starts after the
    /// first two tokens even when those don't parse (e.g. "Zero bytes of 2.15 GB"), so the copied
    /// amount is never mistaken for the total.
    static func bytesTotal(in status: String) -> Int64? {
        let t = tokens(status)
        guard t.count >= 4 else { return nil }
        for i in 2..<(t.count - 1) {
            if let v = amount(t[i], t[i + 1]) { return v }
        }
        return nil
    }

    private static let units: [String: Double] = [
        "bytes": 1, "byte": 1, "B": 1, "Bytes": 1, "Byte": 1, "octets": 1, "octet": 1,
        "KB": 1e3, "kB": 1e3, "Ko": 1e3, "MB": 1e6, "Mo": 1e6, "GB": 1e9, "Go": 1e9, "TB": 1e12, "To": 1e12,
    ]

    private static func tokens(_ s: String) -> [Substring] {
        s.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" })
    }

    /// One "<number> <unit>" pair -> bytes. Plain byte counts can carry thousands separators
    /// ("1,234 bytes"); scaled values carry a decimal separator ("1.52 GB", "1,52 GB").
    private static func amount(_ number: Substring, _ unitToken: Substring) -> Int64? {
        let unitName = unitToken.trimmingCharacters(in: .punctuationCharacters)
        guard let unit = units[unitName] else { return nil }
        let num = unit == 1
            ? String(number.filter(\.isNumber))
            : number.replacingOccurrences(of: ",", with: ".")
        guard !num.isEmpty, let v = Double(num), v >= 0 else { return nil }
        return Int64((v * unit).rounded())
    }
}
