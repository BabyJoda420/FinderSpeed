// Engine/Transfer.swift (owner: athena)
// Value types published by TransferMonitor. Shared contract, see BRIEF.md "Phase 2".

import Foundation

/// One raw speed measurement, taken each time Finder's byte counter changes (~every 0.5 s).
public struct SpeedSample: Hashable, Sendable, Identifiable {
    public let time: Date
    public let bytesPerSecond: Double
    /// The transfer's cumulative bytesCompleted at the END of this sample's segment (the same value
    /// `Transfer.bytesCompleted` had then, including the window-text fallback). For an x-axis in
    /// percent complete: bytesCompleted / bytesTotal. 0 if unknown (e.g. hand-made samples).
    public let bytesCompleted: Int64

    public init(time: Date, bytesPerSecond: Double, bytesCompleted: Int64 = 0) {
        self.time = time
        self.bytesPerSecond = bytesPerSecond
        self.bytesCompleted = bytesCompleted
    }
    /// TransferMonitor emits at most one sample per transfer per poll, so time is unique.
    public var id: Date { time }
}

/// One Finder operation, grouped by destination folder. A multi-item copy into one folder
/// is a single Transfer, even though Finder publishes one NSProgress per top-level item.
public struct Transfer: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The folder the items are being copied into.
    public var destinationFolder: URL
    /// The item name for a single item, otherwise "N items".
    public var displayName: String
    /// The names of the top-level items in this transfer, in the order they appeared.
    public var itemNames: [String]
    /// The total bytes copied so far, summed over all items. 0 while preparing.
    public var bytesCompleted: Int64
    /// The total bytes to copy, summed over all items. 0 if not known yet.
    public var bytesTotal: Int64
    /// The smoothed current speed (EMA, time constant ~1.5 s). It decays to 0 when the copy stalls.
    public var bytesPerSecond: Double
    /// Raw samples (time + bytes/sec) for the graph. Capped at the newest `TransferMonitor.maxSamples`.
    public var samples: [SpeedSample]
    /// True until Finder reports the first real bytes (the byte counter is -1 or 0).
    public var isPreparing: Bool
    /// When the first NSProgress of this transfer was published.
    public var startedAt: Date

    // Extras beyond the contract
    /// True once every item's progress has been unpublished. The transfer stays in
    /// `transfers` for `TransferMonitor.finishedLinger` seconds after that, then is removed.
    public var isFinished: Bool
    public var finishedAt: Date?
    /// True if it finished with bytesCompleted < bytesTotal or a progress reported isCancelled.
    public var wasCancelled: Bool
    /// The average speed over the actual copying time (preparing excluded). Set when finished,
    /// and also kept up to date while running.
    public var averageBytesPerSecond: Double?
    /// True while bytes are flowing but there is no speed estimate yet: the first ~1 s after the
    /// engine joins a copy that is already running (late attach, e.g. via a Finder-window hint), or
    /// right after preparing. `bytesPerSecond` is 0 and `averageBytesPerSecond` nil then: show
    /// "Measuring…", not "0 KB/s".
    public var isMeasuring: Bool = false
    /// True once bytesCompleted/speed come from Finder's window text instead of NSProgress
    /// (Finder's NSProgress undercounted; see TransferMonitor.noteWindowRow).
    public var usesWindowFallback: Bool = false

    public var fractionCompleted: Double {
        bytesTotal > 0 ? min(1, max(0, Double(bytesCompleted) / Double(bytesTotal))) : 0
    }
    /// The display name of the destination folder ("athena", "Macintosh HD", ...).
    public var destinationDisplayName: String {
        FileManager.default.displayName(atPath: destinationFolder.path)
    }
}
