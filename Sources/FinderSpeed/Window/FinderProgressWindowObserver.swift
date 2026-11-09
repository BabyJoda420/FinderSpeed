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

        // Process-wide AX timeout: elements derived from the app element (window, rows) don't inherit
        // its timeout and would otherwise wait up to the 6 s default. (Reads are off the main thread.)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
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

    /// All AX reads run here (BUG-001: synchronous AX calls to a busy Finder blocked the main thread).
    private let axQueue = DispatchQueue(label: "finder-speed.ax", qos: .userInitiated)
    /// Bumped on track/untrack/detach; results from an older generation are dropped.
    private var generation = 0
    private var attachInFlight = false
    private var scanInFlight = false
    private var verifyInFlight = false
    private var readInFlight = false
    private var readPending = false
    private var pendingTrigger: Event?
    private var consecutiveFailures = 0
    private var lastIsMain = false

    nonisolated private static let progressIdentifier = "Progress"
    private static let messagingTimeout: Float = 1.0

    nonisolated private static func isFinder(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == FinderApp.bundleID
    }

    private func log(_ s: @autoclosure () -> String) {
        if WindowDiagnostics.enabled { WindowDiagnostics.log("observer", s()) }
        else if debugLogging { print("[window] \(s())"); fflush(stdout) }
    }

    private func emit(_ event: Event) {
        if event != .rowsChanged {
            log("event \(event) frame=\(window.map { "\($0.frame)" } ?? "-") active=\(window?.isActive ?? false) rows=\(window?.rowCount ?? 0)")
        }
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
        guard started, AccessibilityPermission.isTrusted, !attachInFlight else { return }
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
        // Registering talks to Finder (IPC): do it off the main thread.
        attachInFlight = true
        let refcon = UncheckedBox(Unmanaged.passUnretained(self).toOpaque())
        let box = UncheckedBox((obs, app))
        axQueue.async { [weak self] in
            var ok = true
            for n in [kAXWindowCreatedNotification, kAXValueChangedNotification,
                      kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                let err = AXObserverAddNotification(box.value.0, box.value.1, n as CFString, refcon.value)
                if err != .success && err != .notificationAlreadyRegistered {
                    WindowDiagnostics.log("observer", "add \(n) on app failed: \(err.rawValue)")
                    if n == kAXWindowCreatedNotification { ok = false }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.attachInFlight = false
                    guard self.started else { return }
                    // Typically kAXErrorCannotComplete right after Finder launches: retry.
                    guard ok else { self.scheduleAttach(after: 1); return }
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(box.value.0), .commonModes)
                    self.finderPid = pid
                    self.appElement = box.value.1
                    self.axObserver = box.value.0
                    self.isAttached = true
                    self.log("attached to Finder pid \(pid)")
                    self.scanForProgressWindow()
                }
            }
        }
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
        generation += 1
    }

    // MARK: Window tracking (BUG-001: every AX read runs on `axQueue`, never on the main thread)

    nonisolated private static func isProgressWindow(_ e: AXUIElement) -> Bool {
        AX.string(e, kAXIdentifierAttribute) == progressIdentifier
    }

    nonisolated private static let windowNotifications = [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                                              kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    /// Looks for Finder's Progress window. A failed window list changes nothing.
    private func scanForProgressWindow() {
        guard let app = appElement, windowElement == nil, !scanInFlight else { return }
        scanInFlight = true
        let gen = generation
        let box = UncheckedBox(app)
        axQueue.async { [weak self] in
            let wins = AX.windows(box.value)
            let found = wins?.first(where: { Self.isProgressWindow($0) })
            let result = UncheckedBox((wins == nil, found))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanInFlight = false
                    guard gen == self.generation else { return }
                    if result.value.0 { self.log("scan: window list failed (kept state)") }
                    if let w = result.value.1, self.windowElement == nil { self.track(w) }
                }
            }
        }
    }

    /// Starts tracking `w` (it has AXIdentifier "Progress"). The first read emits `.appeared`.
    private func track(_ w: AXUIElement) {
        guard let obs = axObserver else { return }
        if let cur = windowElement {
            if CFEqual(cur, w) { return }
            untrackWindow()
        }
        windowElement = w
        generation += 1
        AXUIElementSetMessagingTimeout(w, Self.messagingTimeout)
        let refcon = UncheckedBox(Unmanaged.passUnretained(self).toOpaque())
        let box = UncheckedBox((obs, w))
        axQueue.async {
            for n in Self.windowNotifications {
                let err = AXObserverAddNotification(box.value.0, box.value.1, n as CFString, refcon.value)
                if err != .success && err != .notificationAlreadyRegistered {
                    WindowDiagnostics.log("observer", "add \(n) on window failed: \(err.rawValue)")
                }
            }
        }
        reread(trigger: nil)
    }

    private func untrackWindow() {
        if let obs = axObserver, let w = windowElement {
            let box = UncheckedBox((obs, w))
            axQueue.async {
                for n in Self.windowNotifications { AXObserverRemoveNotification(box.value.0, box.value.1, n as CFString) }
            }
        }
        windowElement = nil
        generation += 1
        readInFlight = false; readPending = false; pendingTrigger = nil
        consecutiveFailures = 0
        if window != nil {
            window = nil
            log("disappeared")
            emit(.disappeared)
        }
    }

    /// Outcome of one background read of the tracked window.
    private enum ReadResult {
        /// The element is invalid: the window is really gone.
        case gone
        /// Finder didn't answer (timeout, kAXErrorCannotComplete, ...): keep everything we knew.
        case failed(AXError)
        case ok(RawInfo)
    }

    /// Values read on `axQueue`; nil fields failed to read and keep their previous value.
    private struct RawInfo {
        let axFrame: CGRect
        let windowID: CGWindowID?
        let rows: [Row]?
        let isMinimized: Bool?
        let isMain: Bool?
    }

    /// Re-reads the tracked window off the main thread and applies the result on the main thread.
    /// Coalesced: while a read is in flight, further requests collapse into one follow-up read.
    private func reread(trigger: Event?) {
        guard let w = windowElement else { return }
        if readInFlight {
            readPending = true
            if trigger == .orderingMayHaveChanged { pendingTrigger = trigger }
            return
        }
        readInFlight = true
        let gen = generation, pid = finderPid
        let box = UncheckedBox(w)
        axQueue.async { [weak self] in
            let t0 = Date()
            let result = UncheckedBox(Self.read(box.value, pid: pid))
            let ms = Date().timeIntervalSince(t0) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard gen == self.generation else { return }   // untracked/detached meanwhile
                    self.readInFlight = false
                    if ms > 250 { self.log(String(format: "read took %.0f ms", ms)) }
                    self.apply(result.value, trigger: trigger)
                    if self.readPending, self.windowElement != nil {
                        let t = self.pendingTrigger
                        self.readPending = false; self.pendingTrigger = nil
                        self.reread(trigger: t)
                    }
                }
            }
        }
    }

    private func apply(_ result: ReadResult, trigger: Event?) {
        switch result {
        case .gone:
            log("read: element invalid -> window gone")
            untrackWindow()
            scanForProgressWindow()
        case .failed(let err):
            consecutiveFailures += 1
            log("read failed (\(err.rawValue)), keeping last info (\(consecutiveFailures) in a row)")
            if window != nil, trigger == .orderingMayHaveChanged { emit(.orderingMayHaveChanged) }
        case .ok(let raw):
            consecutiveFailures = 0
            let old = window
            if let m = raw.isMain { lastIsMain = m }
            let wid = raw.windowID ?? old?.windowID ?? CGWindows.finderWindowID(matching: raw.axFrame, pid: finderPid)
            let info = WindowInfo(
                windowID: wid,
                frame: ScreenGeometry.appKitRect(fromTopLeft: raw.axFrame),
                axFrame: raw.axFrame,
                rows: raw.rows ?? old?.rows ?? [],
                isMinimized: raw.isMinimized ?? old?.isMinimized ?? false,
                isActive: NSWorkspace.shared.frontmostApplication?.processIdentifier == finderPid && lastIsMain
            )
            window = info
            guard let old else {
                log("appeared: id=\(info.windowID.map(String.init) ?? "nil") frame=\(info.frame) rows=\(info.rowCount)")
                emit(.appeared)
                return
            }
            var events: [Event] = []
            if old.axFrame.origin != info.axFrame.origin { events.append(.moved) }
            if old.axFrame.size != info.axFrame.size { events.append(.resized) }
            if old.isMinimized != info.isMinimized { events.append(.minimizedChanged) }
            if old.isActive != info.isActive { events.append(.activationChanged) }
            if old.rows != info.rows { events.append(.rowsChanged) }
            if events.isEmpty, trigger == .orderingMayHaveChanged { events.append(.orderingMayHaveChanged) }
            if old.windowID != info.windowID && !events.contains(.orderingMayHaveChanged) { events.append(.orderingMayHaveChanged) }
            for e in events { emit(e) }
        }
    }

    /// Runs on `axQueue`. Only kAXErrorInvalidUIElement means "gone".
    nonisolated private static func read(_ w: AXUIElement, pid: pid_t) -> ReadResult {
        var role: AnyObject?
        let err = AX.copy(w, kAXRoleAttribute, &role)
        if err == .invalidUIElement { return .gone }
        if err != .success { return .failed(err) }
        guard let axFrame = AX.frame(w) else { return .failed(.cannotComplete) }
        return .ok(RawInfo(axFrame: axFrame, windowID: AX.windowID(w), rows: readRows(w),
                           isMinimized: AX.bool(w, kAXMinimizedAttribute), isMain: AX.bool(w, kAXMainAttribute)))
    }

    /// Runs on `axQueue`. Rows by element order: each AXProgressIndicator starts a row; its title is
    /// the last static text before it, its status the first static text after it. Returns nil if any
    /// read failed (the caller keeps the previous rows instead of publishing partial ones).
    nonisolated private static func readRows(_ w: AXUIElement) -> [Row]? {
        func attr(_ e: AXUIElement, _ name: String) -> (AXError, AnyObject?) {
            var v: AnyObject?; let err = AX.copy(e, name, &v); return (err, v)
        }
        let (ce, cv) = attr(w, kAXChildrenAttribute)
        guard ce == .success, let top = cv as? [AXUIElement] else { return nil }
        var container = w
        for c in top {
            let (re, rv) = attr(c, kAXRoleAttribute)
            guard re == .success || re == .noValue else { return nil }
            if rv as? String == kAXScrollAreaRole as String { container = c; break }
        }
        var elements: [AXUIElement] = []
        var failed = false
        func walk(_ e: AXUIElement, _ depth: Int) {
            let (err, v) = attr(e, kAXChildrenAttribute)
            if err != .success && err != .noValue && err != .attributeUnsupported { failed = true; return }
            for c in (v as? [AXUIElement]) ?? [] {
                elements.append(c)
                if depth < 4 { walk(c, depth + 1) }
            }
        }
        walk(container, 1)
        if failed { return nil }
        var rows: [(title: String, status: String?, fraction: Double?)] = []
        var pendingText: String?
        for e in elements {
            let (re, rv) = attr(e, kAXRoleAttribute)
            guard re == .success || re == .noValue else { return nil }
            switch rv as? String {
            case kAXStaticTextRole?:
                let (ve, vv) = attr(e, kAXValueAttribute)
                guard ve == .success || ve == .noValue else { return nil }
                let text = vv as? String ?? ""
                if let last = rows.indices.last, rows[last].status == nil { rows[last].status = text } else { pendingText = text }
            case kAXProgressIndicatorRole?:
                let (ve, vv) = attr(e, kAXValueAttribute)
                guard ve == .success || ve == .noValue else { return nil }
                rows.append((pendingText ?? "", nil, (vv as? NSNumber)?.doubleValue))
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

    /// A SUCCESSFUL window list without our element means the window is gone (BUG-001 (a)).
    private func verifyTracked() {
        guard let app = appElement, let w = windowElement, !verifyInFlight else { return }
        verifyInFlight = true
        let gen = generation
        let box = UncheckedBox((app, w))
        axQueue.async { [weak self] in
            let wins = AX.windows(box.value.0)
            let missing = wins.map { list in !list.contains(where: { CFEqual($0, box.value.1) }) } ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.verifyInFlight = false
                    guard gen == self.generation, missing else { return }
                    self.log("window list no longer contains the Progress window -> gone")
                    self.untrackWindow()
                    self.scanForProgressWindow()
                }
            }
        }
    }

    private func scheduleRowRefresh() {
        reread(trigger: nil)   // coalesced in reread
    }

    private func emitOrderingHint() {
        guard window != nil else { return }
        emit(.orderingMayHaveChanged)
    }

    /// Activation or focus changed somewhere: re-read (isActive may have changed) and let the panel
    /// re-check its ordering right away (the read result follows).
    private func focusMayHaveChanged() {
        guard windowElement != nil else { return }
        emitOrderingHint()
        reread(trigger: .orderingMayHaveChanged)
    }

    private func safetyTick() {
        guard started else { return }
        if !isAttached {
            if AccessibilityPermission.isTrusted, FinderApp.running != nil { attach() }
            return
        }
        if let f = FinderApp.running, f.processIdentifier != finderPid { attach(); return }
        if windowElement == nil { scanForProgressWindow() } else { reread(trigger: .orderingMayHaveChanged); verifyTracked() }
    }

    // MARK: AX callback (main thread; no AX calls here, only scheduling)

    fileprivate func handle(notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            if windowElement == nil { checkCandidate(element) }
            if notification != kAXWindowCreatedNotification { focusMayHaveChanged() }
        case kAXValueChangedNotification:
            if windowElement != nil { scheduleRowRefresh() } else { checkCandidate(element, viaWindowAttribute: true) }
        case kAXMovedNotification, kAXResizedNotification,
             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            reread(trigger: nil)
        case kAXUIElementDestroyedNotification:
            if let cur = windowElement, CFEqual(cur, element) {
                log("destroyed notification -> window gone")
                untrackWindow()
                scanForProgressWindow()
            } else {
                reread(trigger: nil)   // a read reports .gone if it was ours
            }
        default:
            break
        }
    }

    /// Checks off the main thread whether `element` (or its window) is the Progress window.
    private func checkCandidate(_ element: AXUIElement, viaWindowAttribute: Bool = false) {
        let gen = generation
        let box = UncheckedBox(element)
        axQueue.async { [weak self] in
            var candidate: AXUIElement? = box.value
            if viaWindowAttribute {
                if let v = AX.attribute(box.value, kAXWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() {
                    candidate = (v as! AXUIElement)
                } else { candidate = nil }
            }
            guard let c = candidate, Self.isProgressWindow(c) else { return }
            let found = UncheckedBox(c)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, self.windowElement == nil else { return }
                    self.track(found.value)
                }
            }
        }
    }
}

/// Moves non-Sendable CF references between the main thread and `axQueue`. AXUIElement and
/// AXObserver are thread-safe CF types.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
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
