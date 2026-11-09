// Phase 3 regression: graph spikes during a real Finder copy (owner: athena).
//
// Real case (build/captures/before/shot-2.png): an 8 × 1 GiB folder copy at ~140 MB/s (Finder's own
// text: 6.18 GB at 42.4 s; the graph's "avg 142 MB/s" was right; the copy-test log's 61 MB/s came
// from a second, overlapping copy that damaged the destination). The graph showed one 719 MB/s
// spike (5x, no dip to 0 before it) and smaller ~1.7x bumps about every 7.3 s (one per 1 GiB file).
//
// Cause: each raw sample was timed over ONE ~0.5 s segment between the moments WE saw Finder's
// counter (0.1 s polls, XPC delivery, main-thread stalls). When a steady delivery lag clears, the
// previous sample sat on a stale value and the next ~0.5 s segment carries 2+ s of bytes.
// Fix: (1) a median over the last 5 raw rates drops such outliers; (2) each raw rate spans >= 0.6 s
// of real counter history; (3) synthetic stall zeros never reset that history; (4) the first value
// after preparing only starts the history. Replay peaks, old -> new: clearing lag 3.0 -> 1.02,
// rare 0.8-1.6 s delays 2.5 -> 1.13, heavy jitter 1.8 -> 1.27, per-file bursts 1.56 -> 1.02.

import Foundation
import Testing
@testable import FinderSpeed

/// Deterministic RNG so replays are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One Finder counter tick: the value Finder published at `tick`, visible to us from `arrival`.
struct Tick { let tick: Double; let arrival: Double; let bytes: Int64 }

enum FinderModel {
    static let granule = 8.0 * 1_048_576   // Finder's counter moves in 8 MiB steps (spike-A logs)

    /// Finder publishes its byte counter every 0.5 s at `rate`. Inner files of `fileSize` hold back
    /// up to `holdBack` bytes that are only reported when the file completes (catch-up burst).
    /// `delay(t)` is when the tick reaches our main thread; arrivals never go out of order.
    static func ticks(seconds: Double, rate: Double, fileSize: Double = .infinity, holdBack: Double = 0,
                      delay: (Double) -> Double) -> [Tick] {
        var out: [Tick] = []
        var lastArrival = 0.0
        var t = 0.5
        while t <= seconds + 1e-9 {
            let trueBytes = rate * t
            let held = min(holdBack, trueBytes.truncatingRemainder(dividingBy: fileSize))
            let reported = ((trueBytes - held) / granule).rounded(.down) * granule
            let arrival = max(lastArrival, t + delay(t))
            lastArrival = arrival
            out.append(Tick(tick: t, arrival: arrival, bytes: Int64(reported)))
            t += 0.5
        }
        return out
    }

    /// Random delivery delays: mostly 0...small, a fraction `bigShare` of updates bigMin...bigMax late.
    static func jitter(seed: UInt64, small: Double, bigShare: Double = 0, bigMin: Double = 0, bigMax: Double = 0)
        -> (Double) -> Double {
        var rng = SplitMix64(state: seed)
        return { _ in
            Double.random(in: 0..<1, using: &rng) < bigShare
                ? Double.random(in: bigMin...bigMax, using: &rng)
                : Double.random(in: 0...small, using: &rng)
        }
    }
}

/// Feeds `ticks` (and optional window-row ticks) to the monitor with its normal 0.1 s poll.
@MainActor
func replay(_ ticks: [Tick], window: [Tick]? = nil, monitor m: TransferMonitor, clock c: FakeClock,
            dest: URL = URL(fileURLWithPath: "/V/dest"), total: Int64) -> [SpeedSample] {
    let p = finderProgress(dest.appendingPathComponent("folder").path)
    let start = c.now
    m.handlePublished(id: UUID(), progress: p, subscribedPath: dest.path)
    setBytes(p, 0, total); m.poll()
    let end = max(ticks.last?.arrival ?? 0, window?.last?.arrival ?? 0) + 0.5
    var i = 0, w = 0, step = 0
    while Double(step) * 0.1 < end {
        step += 1
        let t = Double(step) * 0.1
        c.now = start.addingTimeInterval(t)
        while i < ticks.count && ticks[i].arrival <= t + 1e-9 { setBytes(p, ticks[i].bytes); i += 1 }
        if let window {
            while w < window.count && window[w].arrival <= t + 1e-9 {
                m.noteWindowRow(destination: dest, bytesCompleted: window[w].bytes, bytesTotal: total, timestamp: c.now)
                w += 1
            }
        }
        m.poll()
    }
    return m.transfers.first?.samples ?? []
}

/// Peak raw sample relative to the true rate.
func peakRatio(_ s: [SpeedSample], rate: Double) -> Double { (s.map(\.bytesPerSecond).max() ?? 0) / rate }

@Suite("Spike replays (Phase 3)")
@MainActor
struct SpikeReplayTests {
    let rate = 140e6
    let total: Int64 = 8 << 30

    /// The screenshot case: steady 140 MB/s; our view of Finder's counter lags a steady 1.5 s (main
    /// thread or XPC behind), then the lag clears at t = 9 s. One 0.5 s segment then carries 2 s of
    /// bytes: a single ~4-5x sample after a normal plateau, with no dip to 0, like the screenshot.
    @Test func clearingDeliveryLagDoesNotSpike() {
        let (m, c) = makeMonitor()
        let ticks = FinderModel.ticks(seconds: 20, rate: rate, delay: { $0 <= 9 ? 1.5 : 0.05 })
        let s = replay(ticks, monitor: m, clock: c, total: total)
        #expect(peakRatio(s, rate: rate) < 1.3)
    }

    /// One single update delivered 1.3 s late (the following ones bunch up behind it).
    @Test func oneLateUpdateDoesNotSpike() {
        let (m, c) = makeMonitor()
        let ticks = FinderModel.ticks(seconds: 20, rate: rate, delay: { abs($0 - 9) < 0.01 ? 1.3 : 0.05 })
        let s = replay(ticks, monitor: m, clock: c, total: total)
        #expect(peakRatio(s, rate: rate) < 1.3)
    }

    /// Updates stop reaching us for 2.4 s (main thread busy, XPC hiccup) while Finder keeps copying.
    /// The stall zeros are fine; the burst after them must not be divided by the last 0.5 s.
    /// Checked with and without the median: keeping stall zeros out of the rate history must hold
    /// on its own (the median would otherwise hide a regression there).
    @Test(arguments: [5, 1])
    func deliveryStallDoesNotSpikeAfterwards(medianWidth: Int) {
        let (m, c) = makeMonitor()
        m.medianWidth = medianWidth
        let ticks = FinderModel.ticks(seconds: 20, rate: rate, delay: { _ in 0.05 }).map {
            ($0.tick > 9 && $0.tick <= 11.4) ? Tick(tick: $0.tick, arrival: 11.45, bytes: $0.bytes) : $0
        }
        let s = replay(ticks, monitor: m, clock: c, total: total)
        #expect(s.contains { $0.bytesPerSecond == 0 })     // the stall itself is shown
        #expect(peakRatio(s, rate: rate) < 1.3)
    }

    /// Normal timing noise (0.1 s poll phase, 0-0.6 s delivery delays) plus rare 0.8-1.6 s delays,
    /// over many seeds; this includes the very first update arriving late (several ticks at once).
    @Test(arguments: Array(UInt64(1)...20))
    func jitterStaysBounded(seed: UInt64) {
        var (m, c) = makeMonitor()
        let mild = replay(FinderModel.ticks(seconds: 40, rate: rate, delay: FinderModel.jitter(seed: seed, small: 0.6)),
                          monitor: m, clock: c, total: total)
        #expect(peakRatio(mild, rate: rate) < 1.5)

        (m, c) = makeMonitor()
        let rare = replay(FinderModel.ticks(seconds: 40, rate: rate,
                                            delay: FinderModel.jitter(seed: seed, small: 0.15, bigShare: 0.05, bigMin: 0.8, bigMax: 1.6)),
                          monitor: m, clock: c, total: total)
        #expect(peakRatio(rare, rate: rate) < 1.8)
    }

    /// Per-file catch-up bursts in a folder of 1 GiB files (the ~7.3 s bumps).
    @Test func innerFileCatchUpBurstsAreDamped() {
        let (m, c) = makeMonitor()
        let ticks = FinderModel.ticks(seconds: 40, rate: rate, fileSize: 1_073_741_824, holdBack: 60e6, delay: { _ in 0.05 })
        let s = replay(ticks, monitor: m, clock: c, total: total)
        #expect(peakRatio(s, rate: rate) < 1.35)
    }

    /// Window-row fallback: NSProgress frozen, Finder's text in 10 MB steps at 61 MB/s (the quantised
    /// case from the brief) with delivery jitter.
    @Test(arguments: [UInt64(1), 2, 3])
    func windowFallbackQuantisedTextStaysBounded(seed: UInt64) {
        let slow = 61e6
        let (m, c) = makeMonitor()
        let delay = FinderModel.jitter(seed: seed, small: 0.6)
        var last = 0.0
        let win: [Tick] = stride(from: 0.5, through: 40, by: 0.5).map { t in
            let a = max(last, t + delay(t)); last = a
            return Tick(tick: t, arrival: a, bytes: Int64(slow * t) / 10_000_000 * 10_000_000)
        }
        let s = replay([Tick(tick: 0.5, arrival: 0.5, bytes: 30_000_000)], window: win, monitor: m, clock: c, total: total)
        #expect(m.transfers.first?.usesWindowFallback == true)
        let copying = s.filter { $0.bytesPerSecond > 0 }   // NSProgress stall zeros before the switch are fine
        #expect(!copying.isEmpty)
        #expect(peakRatio(copying, rate: slow) < 1.5)
    }

    /// Filtering must not bias the numbers. With realistic timing noise (poll phase + 0-0.15 s
    /// delivery delays; the real 4 GB run showed samples 0.50 +- 0.01 s apart) the plain mean of
    /// the graphed samples stays within 3 % of the true rate, and the engine's average (the dashed
    /// line) within 3 % even under heavy 0-0.6 s jitter on every update. (Under that heavy jitter the
    /// graphed samples read ~15 % low, with or without the median: the minSegment spacing skips the
    /// quick catch-up changes. Known limitation; the average is unaffected.)
    @Test(arguments: [UInt64(2), 7, 11])
    func averagesStayUnbiased(seed: UInt64) {
        var (m, c) = makeMonitor()
        let s = replay(FinderModel.ticks(seconds: 40, rate: rate, delay: FinderModel.jitter(seed: seed, small: 0.15)),
                       monitor: m, clock: c, total: total)
        let plainMean = s.map(\.bytesPerSecond).reduce(0, +) / Double(s.count)
        #expect(approx(plainMean, rate, rel: 0.03))
        #expect(approx(m.transfers[0].averageBytesPerSecond ?? 0, rate, rel: 0.03))

        (m, c) = makeMonitor()
        _ = replay(FinderModel.ticks(seconds: 40, rate: rate, delay: FinderModel.jitter(seed: seed, small: 0.6)),
                   monitor: m, clock: c, total: total)
        #expect(approx(m.transfers[0].averageBytesPerSecond ?? 0, rate, rel: 0.03))
    }
}
