// Engine/TransferMonitor.swift (owner: athena)
//
// Watches Finder copy progress through Progress.addSubscriber(forFileURL:) and turns it into
// `Transfer` values with a smoothed speed and raw samples.
//
// Facts from Spike A (spikes/progress/REPORT.md) this code relies on:
//  * Bytes are only in userInfo["NSProgressByteCompletedCountKey"/"...TotalCountKey"].
//    completedUnitCount is per-mille. throughput is always nil.
//  * Finder updates the byte counter at ~2 Hz, and only when it changed.
//  * One NSProgress per top-level destination item. Subscriptions match only the item URL or its
//    DIRECT parent folder (not recursive), so we subscribe to a set of candidate folders.
//  * fileURL can be nil for a few ms right after publishing.
//  * Subscribing late delivers progresses that are already running, immediately.
//  * FIOperationUUID is always zero, so items are grouped by destination parent folder.

import AppKit
import Foundation

@MainActor
public final class TransferMonitor: ObservableObject {

    // MARK: Public state

    @Published public private(set) var transfers: [Transfer] = []

    // MARK: Tunables

    /// How often userInfo is polled. Only actual changes are timestamped.
    public var pollInterval: TimeInterval = 0.1
    /// Time constant of the EMA used for `bytesPerSecond`.
    public var smoothingTimeConstant: TimeInterval = 1.5
    /// Finder's nominal counter cadence. Caps the first interval after "preparing".
    public var nominalCadence: TimeInterval = 0.5
    /// Minimum time without a counter change before a copy counts as stalled (then a 0 sample is
    /// emitted every `nominalCadence`). The real threshold is adaptive, see `stallFactor`.
    public var stallThreshold: TimeInterval = 2.0
    /// BUG-001: Finder's counter moves in 8 MiB granules, so a slow copy (3.4 MB/s to a USB HDD)
    /// only changes every ~2.5 s, and per-file updates can be sparser still. Each copy's update
    /// interval is learned (median of its recent intervals); it only counts as stalled after
    /// `stallFactor` x that interval (and at least `stallThreshold`). Until then the last rate is held.
    public var stallFactor: Double = 3.0
    /// Stall threshold before a copy's cadence is known (until its first interval is measured).
    public var initialStallAfter: TimeInterval = 5.0
    /// Segments shorter than this are not turned into samples: their bytes roll into the next
    /// segment, or are dropped from the graph if it was the final one. Our timestamps are poll
    /// times (0.1 s granularity), so a short segment would amplify that error into a spike.
    public var minSegment: TimeInterval = 0.3
    // Phase 3 (graph spikes). Our timestamps are when WE saw a counter value (0.1 s polls, XPC
    // delivery, main-thread delays), not when Finder produced it. When that lag changes (e.g. a
    // steady 1.5 s lag clears), one ~0.5 s segment carries several seconds of bytes: a 140 MB/s
    // copy showed a single 719 MB/s sample. Replays (SpikeReplayTests): old 3.0x, now 1.02x.

    /// Each raw rate spans at least ~this much REAL counter history (stall zeros never reset it),
    /// so a single short or poll-phase-shifted segment can't dominate.
    public var rawRateWindow: TimeInterval = 0.6
    /// Each graphed sample is the median of the last `medianWidth` raw rates (odd; 1 disables).
    /// Rejects outliers up to 2 samples long; a real speed change shows ~2 samples (~1 s) later.
    public var medianWidth = 5
    /// How long a finished transfer stays in `transfers`.
    public var finishedLinger: TimeInterval = 4.0
    /// A new item in the same folder within this time after finishing revives the old transfer.
    public var reviveWindow: TimeInterval = 1.0
    /// How long a folder fed in through `noteFinderDestination` stays subscribed once idle.
    public var finderHintLifetime: TimeInterval = 600
    public static let maxSamples = 2400   // 20 min at 2 Hz

    // MARK: Test seams (internal; tests use @testable import)

    /// The time source. Tests replace it with a fake clock.
    var clock: () -> Date = { Date() }
    /// When false, no poll timer is scheduled. Tests call `poll()` by hand.
    var autoPoll = true
    /// The per-transfer sample cap. Defaults to `maxSamples`.
    var sampleCap = TransferMonitor.maxSamples

    // MARK: Event log (opt-in: FINDERSPEED_ENGINE_LOG=1 in the environment)

    var eventLog: ((String) -> Void)? = ProcessInfo.processInfo.environment["FINDERSPEED_ENGINE_LOG"] == "1"
        ? { msg in
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
            FileHandle.standardError.write("[engine \(f.string(from: Date()))] \(msg)\n".data(using: .utf8)!)
        } : nil

    private func ev(_ msg: @autoclosure () -> String) { eventLog?(msg()) }
    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(4)) }
    private func tag(_ s: TransferState) -> String { "T\(Self.short(s.id))(\(s.folder.lastPathComponent))" }
    private func tag(_ h: Handle) -> String {
        "h\(Self.short(h.id))[\(h.itemURL?.lastPathComponent ?? "nil") via \((h.subscribedPath as NSString).lastPathComponent) bytes=\(h.bytes)]"
    }

    // MARK: Init / lifecycle

    public init() {}

    /// Released without stop(): don't leave Foundation subscriptions, workspace observers or timers
    /// behind. (Unpublish callbacks fired by removeSubscriber hit a nil WeakMonitor and do nothing.)
    isolated deinit {
        for (_, sub) in subscriptions { Progress.removeSubscriber(sub.token) }
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        housekeepingTimer?.invalidate()
        pollTimer?.invalidate()
    }

    private var started = false
    private var pollTimer: Timer?
    private var housekeepingTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Subscribes to the standard folders and all mounted volumes, and follows mount and unmount
    /// events. Calling it more than once has no extra effect.
    public func start() {
        guard !started else { return }
        started = true

        for url in Self.standardCandidateFolders() { addReason(.standard, for: url) }
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for v in volumes { addReason(.volume, for: v) }

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            // Same filter as start(): skip hidden volumes (Time Machine snapshots, simulator runtimes...).
            let browsable = (try? url.resourceValues(forKeys: [.volumeIsBrowsableKey]))?.volumeIsBrowsable
            guard browsable != false else { return }
            MainActor.assumeIsolated { self?.addReason(.volume, for: url) }
        })
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.removeReason(.volume, for: url) }
        })

        let hk = Timer(timeInterval: 30, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }   // monitor released without stop()
                self.expireFinderHints()
            }
        }
        RunLoop.main.add(hk, forMode: .common)
        housekeepingTimer = hk
    }

    /// Removes all subscriptions (including ones added before `start()`) and stops the timers.
    /// `transfers` is cleared. Safe to call at any time.
    public func stop() {
        started = false
        // Drop our state first: Foundation calls the unpublish handlers synchronously during
        // removeSubscriber, and they must not finish or cancel anything.
        handles.removeAll(); states.removeAll()
        for (_, sub) in subscriptions { Progress.removeSubscriber(sub.token) }
        subscriptions.removeAll()
        hintLastUsed.removeAll()
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()
        housekeepingTimer?.invalidate(); housekeepingTimer = nil
        stopPolling()
        handles.removeAll(); pendingUnpublish.removeAll(); states.removeAll()
        transfers = []
    }

    /// Adds a folder to watch permanently. Copies whose destination is this folder (or the folder
    /// itself, for a folder being copied) will be seen. Watching is NOT recursive.
    public func watch(folder: URL) { addReason(.user, for: folder) }

    /// Stops watching a folder added with `watch(folder:)`. Standard and volume folders stay watched.
    public func unwatch(folder: URL) { removeReason(.user, for: folder) }

    /// Hook for the Window module (apollo): call this with the destination folder read from
    /// Finder's copy window. It is subscribed right away. A running copy is delivered at once,
    /// even though it started earlier. The subscription expires after `finderHintLifetime`
    /// once no transfer uses it. Calling it repeatedly is cheap.
    public func noteFinderDestination(_ folder: URL) {
        let key = Self.key(folder)
        hintLastUsed[key] = clock()
        addReason(.finderHint, for: folder)
    }

    /// The folders currently subscribed (for debugging).
    public var watchedFolders: [URL] {
        subscriptions.values.map(\.url).sorted { $0.path < $1.path }
    }

    // MARK: Subscriptions

    private enum Reason: Hashable { case standard, volume, user, finderHint }

    private struct Subscription {
        let url: URL
        let token: Any
        var reasons: Set<Reason>
    }

    private var subscriptions: [String: Subscription] = [:]
    private var hintLastUsed: [String: Date] = [:]

    private static func key(_ url: URL) -> String {
        var p = url.standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func standardCandidateFolders() -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = [fm.homeDirectoryForCurrentUser]
        let dirs: [FileManager.SearchPathDirectory] = [
            .desktopDirectory, .downloadsDirectory, .documentDirectory,
            .moviesDirectory, .musicDirectory, .picturesDirectory,
        ]
        for d in dirs { urls += fm.urls(for: d, in: .userDomainMask) }
        // Dragging an app out of a DMG is a very common Finder copy.
        urls.append(URL(fileURLWithPath: "/Applications", isDirectory: true))
        return urls
    }

    private func addReason(_ reason: Reason, for url: URL) {
        let k = Self.key(url)
        if subscriptions[k] != nil {
            subscriptions[k]!.reasons.insert(reason)
            return
        }
        let folderURL = URL(fileURLWithPath: k, isDirectory: true)
        let ref = WeakMonitor(self)
        let token = Progress.addSubscriber(forFileURL: folderURL) { progress in
            let id = UUID()
            let box = UncheckedBox(progress)
            Self.onMain { ref.value?.handlePublished(id: id, progress: box.value, subscribedPath: k) }
            return { Self.onMain { ref.value?.handleUnpublished(id: id) } }
        }
        subscriptions[k] = Subscription(url: folderURL, token: token, reasons: [reason])
        ev("subscribe \(k) (\(reason))")
    }

    private func removeReason(_ reason: Reason, for url: URL) {
        let k = Self.key(url)
        guard var sub = subscriptions[k] else { return }
        sub.reasons.remove(reason)
        if sub.reasons.isEmpty {
            removeSubscription(k)
        } else {
            subscriptions[k] = sub
        }
    }

    private var removingSubscriptionPath: String?

    /// Removing a subscription makes Foundation call the unpublish handler of every progress it
    /// delivered, synchronously. That is OUR doing, not the copy ending, so those calls are
    /// ignored and the handles are detached instead (see `detach`).
    private func removeSubscription(_ k: String) {
        guard let sub = subscriptions.removeValue(forKey: k) else { return }
        ev("unsubscribe \(k)")
        removingSubscriptionPath = k
        Progress.removeSubscriber(sub.token)
        removingSubscriptionPath = nil
        for h in Array(handles.values) where h.subscribedPath == k { detach(h) }
        publish()
    }

    /// We stopped receiving updates for `h` while its copy may still be running. If another
    /// subscription delivered the same item (a duplicate), that handle takes over seamlessly.
    /// Otherwise the item's last bytes are kept but it is not called finished or cancelled; a
    /// transfer left with nothing live is removed rather than shown as FINISHED/CANCELLED.
    private func detach(_ h: Handle) {
        handles[h.id] = nil
        guard let s = h.state, !h.isDuplicate, !h.unpublished else { return }
        if let itemKey = h.itemURL.map(Self.key),
           let dup = handles.values.first(where: {
               $0.isDuplicate && $0.state == nil && $0.itemURL.map(Self.key) == itemKey
           }) {
            dup.isDuplicate = false
            dup.state = s
            dup.lastBytes = h.lastBytes; dup.lastChangeAt = h.lastChangeAt
            dup.lastSampleAt = h.lastSampleAt; dup.history = h.history
            dup.rate = h.rate; dup.copyStartedAt = h.copyStartedAt
            dup.baseBytes = h.baseBytes; dup.primed = h.primed
            if dup.itemName == nil { dup.itemName = h.itemName }
            if let i = s.handles.firstIndex(where: { $0 === h }) { s.handles[i] = dup }
            ev("detach \(tag(h)) -> promoted duplicate \(tag(dup)) in \(tag(s))")
            return
        }
        h.unpublished = true
        h.rate = 0
        ev("detach \(tag(h)) from \(tag(s)) (no duplicate)")
        if s.handles.allSatisfy(\.unpublished) { states.removeAll { $0 === s }; ev("remove \(tag(s)) (nothing live)") }
    }

    private func expireFinderHints() {
        let now = clock()
        let busyFolders = Set(states.filter { !$0.isFinished }.map { Self.key($0.folder) })
        for (k, last) in hintLastUsed {
            if busyFolders.contains(k) { hintLastUsed[k] = now; continue }
            if now.timeIntervalSince(last) > finderHintLifetime {
                hintLastUsed[k] = nil
                removeReason(.finderHint, for: URL(fileURLWithPath: k))
            }
        }
    }

    /// Runs `body` on the main actor: synchronously if already on the main thread, otherwise
    /// queued FIFO with GCD (keeps publish/unpublish ordering).
    nonisolated private static func onMain(_ body: @escaping @Sendable @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    // MARK: Per-progress tracking

    private final class Handle {
        let id: UUID
        let progress: Progress
        let subscribedPath: String
        let publishedAt: Date
        var itemURL: URL?
        var itemName: String?
        weak var state: TransferState?
        var isDuplicate = false
        /// Not a Finder file operation (e.g. a media player's "resume position" progress); not polled.
        var ignored = false
        var unpublished = false
        var cancelled = false

        var bytes: Int64 = -1
        var total: Int64 = -1
        var lastBytes: Int64 = -2          // -2 = never read
        var lastChangeAt: Date
        var intervals = UpdateIntervals()  // learned Finder update cadence for this item
        var inStall = false                // a stall zero was emitted since the last change
        var lastRealRate: Double = 0       // the last measured (non-stall) rate
        var lastSampleAt: Date
        var rate: Double = 0               // the latest raw bytes/sec of this item
        var copyStartedAt: Date?           // estimated start of the first timed interval
        var history = RateHistory()       // real counter changes (never the synthetic stall zeros)
        var baseBytes: Int64 = 0           // bytes already copied when we started timing (late attach)
        var primed = true                  // false until a late-attached handle has a timing baseline

        init(id: UUID, progress: Progress, subscribedPath: String, now: Date) {
            self.id = id; self.progress = progress; self.subscribedPath = subscribedPath
            self.publishedAt = now; self.lastChangeAt = now; self.lastSampleAt = now
        }
    }

    private final class TransferState {
        let id = UUID()
        let folder: URL
        let startedAt: Date
        var handles: [Handle] = []
        var samples: [SpeedSample] = []
        var ema: Double = 0
        var emaInitialized = false
        var rawRecent: [Double] = []       // last raw rates, for the median filter
        var lastSampleAt: Date?
        var isFinished = false
        var finishedAt: Date?
        var wasCancelled = false

        // Finder window fallback (see noteWindowRow)
        var windowBytes: Int64?            // latest "X of Y" count from Finder's window row
        var windowTotal: Int64?
        var windowChangedAt: Date?
        var windowIntervals = UpdateIntervals()
        var windowInStall = false
        var windowLastRealRate: Double = 0
        var windowFirst: (bytes: Int64, at: Date)?
        var windowHistory = RateHistory()
        var windowSampledAt: Date?
        var windowAheadSince: Date?
        var usesWindowBytes = false        // sticky once switched

        init(folder: URL, startedAt: Date) { self.folder = folder; self.startedAt = startedAt }

        var bytesCompleted: Int64 { handles.reduce(0) { $0 + max($1.bytes, 0) } }
        var bytesTotal: Int64 { handles.reduce(0) { $0 + max($1.total, 0) } }
        var copyStartedAt: Date? { handles.compactMap(\.copyStartedAt).min() }
    }

    private var handles: [UUID: Handle] = [:]
    private var pendingUnpublish: Set<UUID> = []   // unpublish arrived before publish (cross-thread)
    private var states: [TransferState] = []

    private static let kBytesDone = ProgressUserInfoKey("NSProgressByteCompletedCountKey")
    private static let kBytesTotal = ProgressUserInfoKey("NSProgressByteTotalCountKey")
    private static let kDisplayName = ProgressUserInfoKey("NSProgressFileDisplayNameKey")
    private static let kFinderOperation = ProgressUserInfoKey("FIOperationUUID")

    /// Finder publishes FIOperationUUID and the byte keys (as -1) from the very first moment.
    /// Other apps publish file progresses too (seen: a 50/100 progress on a .mkv in ~/Movies,
    /// with no operation kind and no byte keys). Those are ignored.
    private static func isFinderFileOperation(_ p: Progress) -> Bool {
        let ui = p.userInfo
        return ui[kFinderOperation] != nil || ui[kBytesTotal] != nil || ui[kBytesDone] != nil
    }

    /// Called (on main) when a subscription delivers a Progress. Internal for tests.
    func handlePublished(id: UUID, progress: Progress, subscribedPath: String) {
        if pendingUnpublish.remove(id) != nil { return }
        let now = clock()
        let h = Handle(id: id, progress: progress, subscribedPath: subscribedPath, now: now)
        handles[id] = h
        read(h)
        ev("publish \(tag(h))")
        tryAssign(h, now: now)
        startPolling()
    }

    /// Called (on main) when a delivered Progress is unpublished. Internal for tests.
    func handleUnpublished(id: UUID) {
        guard let h = handles[id] else { pendingUnpublish.insert(id); return }
        if let r = removingSubscriptionPath, h.subscribedPath == r { return }   // see removeSubscription
        let now = clock()
        read(h)
        ev("unpublish \(tag(h)) total=\(h.total) cancelled=\(h.progress.isCancelled) dup=\(h.isDuplicate) state=\(h.state.map(tag) ?? "none")")
        if let s = h.state, !h.isDuplicate {
            // Final segment: its end is the unpublish delivery time, not Finder's tick, so a partial
            // segment reads high (seen: 0.38 s -> +25 %). Only keep it if it spans a full tick.
            let changed = observeChange(h, now: now, minDt: nominalCadence)
            h.unpublished = true
            h.cancelled = h.progress.isCancelled || (h.total > 0 && h.bytes >= 0 && h.bytes < h.total)
            if changed && !s.usesWindowBytes { emitSample(s, now: now) }
            h.rate = 0
            if s.handles.allSatisfy(\.unpublished) {
                defer { ev("finish \(tag(s)) cancelled=\(s.wasCancelled)") }
                s.isFinished = true
                s.finishedAt = now
                s.wasCancelled = s.handles.contains(where: \.cancelled) || windowSaysCancelled(s)
                s.ema = 0
            }
        }
        h.unpublished = true
        handles[id] = nil
        publish()
    }

    private func read(_ h: Handle) {
        let ui = h.progress.userInfo
        h.bytes = Self.int64(ui[Self.kBytesDone]) ?? -1
        h.total = Self.int64(ui[Self.kBytesTotal]) ?? -1
        if h.itemURL == nil {
            h.itemURL = h.progress.fileURL ?? (ui[.fileURLKey] as? URL)
        }
        if h.itemName == nil || h.itemName!.isEmpty {
            h.itemName = (ui[Self.kDisplayName] as? String) ?? h.itemURL?.lastPathComponent
        }
    }

    private static func int64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }

    /// Puts the handle into a TransferState once its destination is known.
    private func tryAssign(_ h: Handle, now: Date) {
        guard h.state == nil, !h.isDuplicate, !h.ignored else { return }
        guard Self.isFinderFileOperation(h.progress) else {
            if now.timeIntervalSince(h.publishedAt) > 3.0 { h.ignored = true }
            return
        }
        let folder: URL
        if let item = h.itemURL {
            // Dedupe: the same item seen through two subscriptions (the item itself and its parent).
            let itemKey = Self.key(item)
            if handles.values.contains(where: { $0 !== h && $0.state != nil && $0.itemURL.map(Self.key) == itemKey }) {
                h.isDuplicate = true
                ev("duplicate \(tag(h))")
                return
            }
            folder = item.deletingLastPathComponent()
        } else if now.timeIntervalSince(h.publishedAt) > 2.0 {
            folder = URL(fileURLWithPath: h.subscribedPath, isDirectory: true)   // fallback
            ev("fileURL still nil after 2 s: \(tag(h)) grouped by subscription path")
        } else {
            return   // wait for fileURL (normally arrives within a few ms)
        }
        let fk = Self.key(folder)
        let state: TransferState
        if let live = states.last(where: { Self.key($0.folder) == fk && !$0.isFinished }) {
            state = live
        } else if let recent = states.last(where: {
            Self.key($0.folder) == fk && $0.isFinished
                && now.timeIntervalSince($0.finishedAt ?? .distantPast) < reviveWindow
        }) {
            recent.isFinished = false; recent.finishedAt = nil; recent.wasCancelled = false
            recent.emaInitialized = false; recent.lastSampleAt = nil   // don't ramp up from 0
            recent.rawRecent = []
            state = recent
            ev("revive \(tag(recent))")
        } else {
            state = TransferState(folder: URL(fileURLWithPath: fk, isDirectory: true), startedAt: h.publishedAt)
            states.append(state)
            ev("new \(tag(state)) live=\(states.filter { !$0.isFinished }.map(tag))")
        }
        state.handles.append(h)
        h.state = state
        ev("assign \(tag(h)) -> \(tag(state))")
        if hintLastUsed[fk] != nil { hintLastUsed[fk] = now }
    }

    /// Records a counter change for `h`, if any. Returns true when a raw-rate segment ended
    /// (a real change with bytes > 0, or a synthetic stall sample).
    @discardableResult
    private func observeChange(_ h: Handle, now: Date, minDt: TimeInterval? = nil) -> Bool {
        // First observation of this handle.
        if h.lastBytes == -2 {
            h.lastBytes = h.bytes; h.lastChangeAt = now; h.lastSampleAt = now
            if h.bytes > 0 {
                // Late attach (engine started or folder subscribed mid-copy): the bytes so far
                // were copied over an unknown time. The proxy's first value can also be a stale
                // snapshot, so the NEXT change is the timing baseline.
                h.primed = false
                h.baseBytes = h.bytes
            }
            return false
        }
        if h.bytes != h.lastBytes {
            // Learn the cadence from normal gaps only. A gap that was shown as a stall is still
            // learned if the bytes that arrive with it show copying went on (>= 50 % of the recent
            // rate): then Finder's counter was just quiet. A genuine pause is not learned, so it
            // can't hide the next one.
            if h.lastBytes > 0, h.bytes > h.lastBytes, h.primed {
                let gap = now.timeIntervalSince(h.lastChangeAt)
                let gapRate = Double(h.bytes - h.lastBytes) / max(gap, 0.001)
                if !h.inStall || gapRate >= 0.5 * h.lastRealRate { h.intervals.record(gap) }
            }
            h.inStall = false
            h.lastBytes = h.bytes; h.lastChangeAt = now
            guard h.bytes > 0 else {           // -1 -> 0: still preparing
                h.lastSampleAt = now; h.history = RateHistory()
                return false
            }
            if !h.primed {
                h.primed = true
                h.baseBytes = h.bytes
                h.lastSampleAt = now; h.copyStartedAt = now
                h.history.reset(now, h.bytes)
                return false
            }
            if h.copyStartedAt == nil {
                // First real bytes after preparing. For the AVERAGE, assume they arrived within ~one
                // Finder tick, however long preparing took. For the RATE, this value is only the
                // history start: if its delivery was late it carries several ticks at once, and
                // timing it would spike (replay: 3x).
                h.copyStartedAt = now.addingTimeInterval(-min(now.timeIntervalSince(h.lastSampleAt), nominalCadence))
                h.history.reset(now, h.bytes)
                h.lastSampleAt = now
                return false
            }
            h.history.append(now, h.bytes, window: rawRateWindow)
            // Too soon after the previous sample: no new sample yet (the rate is windowed, so no
            // bytes are lost). At unpublish (`minDt`) a partial final tick is not graphed.
            let since = now.timeIntervalSince(max(h.lastSampleAt, h.copyStartedAt ?? h.lastSampleAt))
            guard since >= (minDt ?? minSegment) else { return false }
            // The update that completes an item carries a catch-up burst (real runs: +25-60 % over
            // its neighbours even on a full 0.5 s segment). Count the bytes, don't graph the burst.
            if h.total > 0 && h.bytes >= h.total {
                h.lastSampleAt = now
                return false
            }
            guard h.history.span >= rawRateWindow * 0.8, let r = h.history.rate else { return false }
            h.rate = r
            h.lastRealRate = r
            h.lastSampleAt = now
            return true
        }
        // No change: after a stall, emit 0 samples at the nominal cadence.
        if h.bytes > 0, h.primed, !h.unpublished,
           now.timeIntervalSince(h.lastChangeAt) >= stallAfter(h.intervals),
           now.timeIntervalSince(h.lastSampleAt) >= nominalCadence {
            h.rate = 0                         // display only: the history is not touched
            h.inStall = true
            h.lastSampleAt = now
            return true
        }
        return false
    }

    @discardableResult
    private func emitSample(_ s: TransferState, now: Date, raw override: Double? = nil) -> Bool {
        let unfiltered = override ?? s.handles.reduce(0.0) { $0 + $1.rate }
        if let last = s.samples.last, last.time >= now { return false }
        let raw: Double
        if unfiltered == 0 {
            // A 0 only comes from a real stall: a deliberate signal, shown at once. It does NOT
            // enter the median's history, or it would suppress the real rates around it
            // (BUG-001: median of [0, 3.4, 0, 3.4, 0] MB/s = 0, so the graph was all zeros).
            raw = 0
        } else if medianWidth > 1 {
            s.rawRecent.append(unfiltered)
            if s.rawRecent.count > medianWidth { s.rawRecent.removeFirst() }
            let sorted = s.rawRecent.sorted()
            raw = sorted[(sorted.count - 1) / 2]   // lower median while filling up
        } else {
            raw = unfiltered
        }
        s.samples.append(SpeedSample(time: now, bytesPerSecond: raw, bytesCompleted: effectiveBytes(s)))
        if s.samples.count > sampleCap { s.samples.removeFirst(s.samples.count - sampleCap) }
        if !s.emaInitialized {
            s.ema = raw; s.emaInitialized = true
        } else {
            s.ema = SpeedMath.emaStep(previous: s.ema, sample: raw,
                                      dt: now.timeIntervalSince(s.lastSampleAt ?? now),
                                      timeConstant: smoothingTimeConstant)
        }
        s.lastSampleAt = now
        return true
    }

    /// No counter change for this long = a real stall (adaptive, BUG-001).
    private func stallAfter(_ i: UpdateIntervals) -> TimeInterval {
        guard let learned = i.learned, let longest = i.longest else { return max(stallThreshold, initialStallAfter) }
        return max(stallThreshold, stallFactor * learned, 1.5 * longest)
    }

    // MARK: Finder window fallback

    /// Allowed lead of the window count over NSProgress: max(floor, fraction × window count).
    /// Finder prints ~3 significant digits ("1.52 GB", "123.4 GB", "1.23 TB"), so the text can sit
    /// up to half a display step (< 1 %) above the true count for as long as the copy stalls.
    var windowTolerance: Int64 = 20_000_000
    var windowToleranceFraction: Double = 0.02

    private func tolerance(for bytes: Int64) -> Int64 {
        max(windowTolerance, Int64(Double(max(bytes, 0)) * windowToleranceFraction))
    }
    /// The window count must stay ahead this long before we switch (the two sources tick at 2 Hz
    /// out of phase, so a short lead is normal).
    var windowSwitchDelay: TimeInterval = 1.5

    /// Feeds one row of Finder's copy window: the parsed "X of Y" byte count (decimal, from
    /// `FinderProgressWindowObserver.Row.statusBytesCompleted`). Robustness fallback for when
    /// Finder's NSProgress undercounts (folder copies whose source is APFS clones): if the window
    /// count stays ahead of the NSProgress count (stalled or lower) for `windowSwitchDelay`, that
    /// transfer switches for good to the window count for `bytesCompleted` and speed.
    ///
    /// **Call it once per destination folder per window snapshot, with the SUM over all rows that
    /// resolve to that folder** (`bytesCompleted` and `bytesTotal` both). The engine keeps one
    /// window count per destination, matching how it groups NSProgresses; feeding rows one by one
    /// makes the last row overwrite the others.
    ///
    /// Matching: by `destination` folder if given; otherwise by `destinationName` (the quoted name
    /// in the row title); with neither, only if exactly one transfer is active. Rows that match no
    /// active transfer are ignored. Pass `bytesTotal` (the "of Y" part) if you have it; it replaces
    /// an NSProgress total that is obviously too small, and lets the engine detect a cancel while
    /// in fallback mode. Pass `timestamp: Date()` taken when the row was read.
    public func noteWindowRow(destination: URL?, destinationName: String? = nil,
                              bytesCompleted: Int64, bytesTotal: Int64? = nil, timestamp: Date) {
        guard bytesCompleted >= 0,
              let s = windowRowState(destination: destination, name: destinationName) else { return }
        if let bytesTotal, bytesTotal > 0 { s.windowTotal = bytesTotal }
        if s.windowBytes != bytesCompleted {
            if let prev = s.windowBytes, bytesCompleted > prev, let at = s.windowChangedAt {
                let gap = timestamp.timeIntervalSince(at)
                let gapRate = Double(bytesCompleted - prev) / max(gap, 0.001)
                if !s.windowInStall || gapRate >= 0.5 * s.windowLastRealRate { s.windowIntervals.record(gap) }
            }
            s.windowInStall = false
            s.windowBytes = bytesCompleted
            s.windowChangedAt = timestamp
            if s.windowFirst == nil { s.windowFirst = (bytesCompleted, timestamp) }
            s.windowHistory.append(timestamp, bytesCompleted, window: rawRateWindow)
            updateWindowFallback(s, now: timestamp)
            if s.usesWindowBytes {
                // Same windowed rate as the NSProgress path. A sample that is too soon, or rejected
                // for its timestamp, loses nothing: the next one covers the same history.
                if timestamp.timeIntervalSince(s.windowSampledAt ?? .distantPast) >= minSegment,
                   s.windowHistory.span >= rawRateWindow * 0.8,
                   let r = s.windowHistory.rate, emitSample(s, now: timestamp, raw: r) {
                    s.windowLastRealRate = r
                    s.windowSampledAt = timestamp
                }
            } else {
                s.windowSampledAt = timestamp
            }
        }
        publish()
    }

    private func windowRowState(destination: URL?, name: String?) -> TransferState? {
        let live = states.filter { !$0.isFinished }
        if let destination {
            let k = Self.key(destination)
            return live.last { Self.key($0.folder) == k }
        }
        if let name {
            let m = live.filter {
                $0.folder.lastPathComponent == name || FileManager.default.displayName(atPath: $0.folder.path) == name
            }
            return m.count == 1 ? m[0] : nil
        }
        return live.count == 1 ? live[0] : nil
    }

    /// In fallback mode NSProgress can't tell a cancel (apollo's clone case ended at "2.15 of 2.15 GB"
    /// either way), so compare the window count with the window total. Allow ~1 s of copying,
    /// since the last window text before the row disappears can lag the end.
    private func windowSaysCancelled(_ s: TransferState) -> Bool {
        guard s.usesWindowBytes, let wb = s.windowBytes, let wt = s.windowTotal, wt > 0 else { return false }
        let slack = tolerance(for: wt) + Int64(max(s.ema, 0) * 1.0)
        return wb + slack < wt
    }

    /// Decides the switch to the window count, and emits 0 samples while the window count stalls.
    private func updateWindowFallback(_ s: TransferState, now: Date) {
        guard let wb = s.windowBytes else { return }
        if !s.usesWindowBytes {
            if wb > s.bytesCompleted + tolerance(for: wb) {
                let since = s.windowAheadSince ?? now
                s.windowAheadSince = since
                if now.timeIntervalSince(since) >= windowSwitchDelay {
                    s.usesWindowBytes = true
                    // New speed source: don't carry over an EMA that the frozen NSProgress decayed.
                    s.emaInitialized = false; s.rawRecent = []
                    ev("window fallback ON \(tag(s)) window=\(wb) ns=\(s.bytesCompleted)")
                }
            } else {
                s.windowAheadSince = nil
            }
            return
        }
        if let changed = s.windowChangedAt, now.timeIntervalSince(changed) >= stallAfter(s.windowIntervals),
           now.timeIntervalSince(s.windowSampledAt ?? changed) >= nominalCadence {
            emitSample(s, now: now, raw: 0)    // display only: windowHistory is not touched
            s.windowInStall = true
            s.windowSampledAt = now
        }
    }

    // MARK: Polling

    private func startPolling() {
        guard autoPoll, pollTimer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }   // monitor released without stop()
                self.poll()
            }
        }
        t.tolerance = pollInterval * 0.1
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// One poll step (normally every `pollInterval` from the timer). Internal for tests.
    func poll() {
        let now = clock()
        var touched: Set<ObjectIdentifier> = []
        for h in handles.values where !h.ignored {
            read(h)
            tryAssign(h, now: now)
            guard let s = h.state, !h.isDuplicate else { continue }
            if observeChange(h, now: now) { touched.insert(ObjectIdentifier(s)) }
        }
        for s in states where touched.contains(ObjectIdentifier(s)) && !s.usesWindowBytes {
            emitSample(s, now: now)
        }
        for s in states where !s.isFinished && s.windowBytes != nil { updateWindowFallback(s, now: now) }

        // Drop finished transfers after the linger time.
        states.removeAll { s in
            let drop = s.isFinished && now.timeIntervalSince(s.finishedAt ?? now) > finishedLinger
            if drop { ev("remove \(tag(s)) (linger over)") }
            return drop
        }
        publish()
        if states.isEmpty && handles.values.allSatisfy(\.ignored) { stopPolling() }
    }

    private func publish() {
        let new = states.map(makeTransfer)
        if new != transfers { transfers = new }
        if !states.isEmpty || handles.values.contains(where: { !$0.ignored }) { startPolling() }
    }

    /// Until the first windowed sample exists (~rawRateWindow after the first bytes), show the rate
    /// over the history so far rather than 0. Display only: not graphed, not fed to the EMA.
    private func provisionalRate(_ s: TransferState) -> Double {
        if s.usesWindowBytes { return s.windowHistory.span >= minSegment ? (s.windowHistory.rate ?? 0) : 0 }
        return s.handles.reduce(0.0) { sum, h in
            sum + ((!h.unpublished && h.history.span >= minSegment) ? (h.history.rate ?? 0) : 0)
        }
    }

    /// The bytesCompleted a Transfer shows: NSProgress bytes, or the window count once in fallback.
    private func effectiveBytes(_ s: TransferState) -> Int64 {
        s.usesWindowBytes ? max(s.bytesCompleted, s.windowBytes ?? 0) : s.bytesCompleted
    }

    private func makeTransfer(_ s: TransferState) -> Transfer {
        let names = s.handles.compactMap(\.itemName)
        let display: String = names.count == 1 ? names[0]
            : names.isEmpty ? s.folder.lastPathComponent
            : "\(names.count) items"
        let done = effectiveBytes(s)
        var total = s.bytesTotal
        let timed = s.handles.reduce(Int64(0)) { $0 + max($1.bytes - $1.baseBytes, 0) }
        var avg: Double? = nil
        if let start = s.copyStartedAt, timed > 0 {
            let end = s.finishedAt ?? s.handles.map(\.lastChangeAt).max() ?? clock()
            let dur = end.timeIntervalSince(start)
            if dur > 0.25 { avg = Double(timed) / dur }
        }
        if s.usesWindowBytes, let wb = s.windowBytes {
            if let first = s.windowFirst, let at = s.windowChangedAt, at.timeIntervalSince(first.at) > 1.0 {
                avg = Double(wb - first.bytes) / at.timeIntervalSince(first.at)
            }
        }
        if let wt = s.windowTotal, wt > 0, total <= 0 || Double(total) < Double(wt) * 0.9 {
            total = wt                                  // NSProgress total obviously too small
        } else if total > 0, done > total + tolerance(for: done) {
            total = 0                                   // too small and the real total is unknown
        }
        let speed = s.isFinished ? 0 : (s.emaInitialized ? s.ema : provisionalRate(s))
        return Transfer(
            id: s.id,
            destinationFolder: s.folder,
            displayName: display,
            itemNames: names,
            bytesCompleted: done,
            bytesTotal: total,
            bytesPerSecond: speed,
            samples: s.samples,
            isPreparing: !s.isFinished && done <= 0,
            startedAt: s.startedAt,
            isFinished: s.isFinished,
            finishedAt: s.finishedAt,
            wasCancelled: s.wasCancelled,
            averageBytesPerSecond: avg,
            isMeasuring: !s.isFinished && done > 0 && s.samples.isEmpty && speed == 0,
            usesWindowFallback: s.usesWindowBytes
        )
    }
}

/// Weak reference to the monitor that can be captured by @Sendable closures.
private final class WeakMonitor: @unchecked Sendable {
    weak var value: TransferMonitor?
    init(_ v: TransferMonitor) { value = v }
}

/// Moves a non-Sendable reference across the subscriber callback boundary. Progress proxies are
/// only touched on the main actor after the hop.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// Recent intervals between real counter changes; `learned` is their median (robust to a single
/// long pause or a burst).
struct UpdateIntervals {
    private(set) var recent: [TimeInterval] = []
    mutating func record(_ dt: TimeInterval) {
        guard dt > 0 else { return }
        recent.append(dt)
        if recent.count > Self.memory { recent.removeFirst() }
    }
    /// How many recent intervals the median runs over.
    static let memory = 20
    /// The longest recent normal gap: a gap that long is evidently part of this copy's rhythm.
    var longest: TimeInterval? { recent.max() }
    var learned: TimeInterval? {
        guard !recent.isEmpty else { return nil }
        let s = recent.sorted()
        return s[s.count / 2]
    }
}

/// Real counter observations used for windowed raw rates. Keeps the newest point that is at least
/// `window` older than the latest one (the reference) and everything after it.
struct RateHistory {
    private(set) var points: [(t: Date, bytes: Int64)] = []

    mutating func reset(_ t: Date, _ bytes: Int64) { points = [(t, bytes)] }

    mutating func append(_ t: Date, _ bytes: Int64, window: TimeInterval) {
        points.append((t, bytes))
        while points.count > 2 && t.timeIntervalSince(points[1].t) >= window { points.removeFirst() }
    }

    /// Time covered from the reference point to the latest point.
    var span: TimeInterval {
        guard let a = points.first, let b = points.last else { return 0 }
        return b.t.timeIntervalSince(a.t)
    }

    /// Bytes per second from the reference point to the latest point.
    var rate: Double? {
        guard points.count >= 2, let a = points.first, let b = points.last, b.t > a.t else { return nil }
        return SpeedMath.rate(bytes: b.bytes - a.bytes, seconds: b.t.timeIntervalSince(a.t))
    }
}

/// Pure speed math, kept separate so it can be unit-tested.
enum SpeedMath {
    /// One step of a time-aware exponential moving average:
    /// alpha = 1 - e^(-dt/tau), so irregular sample spacing is weighted correctly.
    static func emaStep(previous: Double, sample: Double, dt: TimeInterval, timeConstant: TimeInterval) -> Double {
        guard timeConstant > 0 else { return sample }
        let alpha = 1 - exp(-max(dt, 0) / timeConstant)
        return previous + alpha * (sample - previous)
    }

    /// Bytes per second for one segment. Never negative; 0 for an empty interval.
    static func rate(bytes: Int64, seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        return max(0, Double(bytes) / seconds)
    }
}
