// BUG-001 (user report): a slow move to a USB HDD showed "Speed: 46.7 KB/s" with
// "Average 3.40 MB/s · Peak 3.40 MB/s". Replays of a slow copy whose counter updates rarely (owner: athena).

import Foundation
import Testing
@testable import FinderSpeed

@Suite("Slow / bursty copies (BUG-001)")
@MainActor
struct SlowCopyReplayTests {
    let total: Int64 = 4_000_000_000

    /// Finder ticks every 0.5 s but its counter moves in 8 MiB granules (spike A logs), so at
    /// 3.4 MB/s it only changes every ~2.5 s.
    static func granularTicks(rate: Double, seconds: Double, granule: Double = 8 * 1_048_576) -> [Tick] {
        stride(from: 0.5, through: seconds, by: 0.5).map { t in
            Tick(tick: t, arrival: t + 0.05, bytes: Int64((rate * t / granule).rounded(.down) * granule))
        }
    }

    /// The displayed speed (bytesPerSecond) sampled at every 0.1 s poll, after the first estimate.
    @MainActor
    static func displayed(_ ticks: [Tick], monitor m: TransferMonitor, clock c: FakeClock, total: Int64)
        -> (speeds: [Double], samples: [SpeedSample]) {
        let dest = URL(fileURLWithPath: "/V/dest")
        let p = finderProgress(dest.appendingPathComponent("folder").path)
        let start = c.now
        m.handlePublished(id: UUID(), progress: p, subscribedPath: dest.path)
        setBytes(p, 0, total); m.poll()
        var speeds: [Double] = []
        var i = 0, step = 0
        let end = (ticks.last?.arrival ?? 0) + 0.5
        while Double(step) * 0.1 < end {
            step += 1
            c.now = start.addingTimeInterval(Double(step) * 0.1)
            while i < ticks.count && ticks[i].arrival <= Double(step) * 0.1 + 1e-9 { setBytes(p, ticks[i].bytes); i += 1 }
            m.poll()
            if let t = m.transfers.first, !t.isMeasuring, !t.isPreparing { speeds.append(t.bytesPerSecond) }
        }
        return (speeds, m.transfers.first?.samples ?? [])
    }

    @Test func slowGranularCopyShowsSteadySpeed() {
        let rate = 3.4e6
        let (m, c) = makeMonitor()
        let (speeds, samples) = Self.displayed(Self.granularTicks(rate: rate, seconds: 120), monitor: m, clock: c, total: total)
        let t = m.transfers[0]
        #expect(!speeds.isEmpty)
        #expect(speeds.allSatisfy { $0 > 0.7 * rate && $0 < 1.3 * rate })     // held, never decaying to ~0
        #expect(!samples.contains { $0.bytesPerSecond == 0 })                   // no fake stalls
        #expect(samples.count >= 40)                                            // ~one per 8 MiB step
        #expect(approx(samples.map(\.bytesPerSecond).max() ?? 0, rate, rel: 0.3)) // peak from real samples
        #expect(approx(t.averageBytesPerSecond ?? 0, rate, rel: 0.05))
    }

    /// Per-file / bursty updates: irregular gaps of 0.5-6 s (seeded). Once learned, the speed is
    /// held between updates, a normal gap is never mistaken for a stall, and avg/peak are real.
    @Test(arguments: Array(UInt64(1)...10))
    func burstyUpdatesAreHeldNotZeroed(seed: UInt64) {
        let rate = 5e6
        var rng = SplitMix64(state: seed)
        var ticks: [Tick] = []
        var t = 0.0
        while t < 120 {
            t += [0.5, 0.5, 1.0, 2.0, 4.0, 6.0].randomElement(using: &rng)!
            ticks.append(Tick(tick: t, arrival: t + 0.05, bytes: Int64(rate * t)))
        }
        let (m, c) = makeMonitor()
        let start = c.now
        let (speeds, samples) = Self.displayed(ticks, monitor: m, clock: c, total: total)
        // The very first unprecedented long gap may read as a pause (nothing could predict it);
        // once the rhythm is learned (20 s), gaps are held, never zeroed.
        let learned = samples.filter { $0.time > start.addingTimeInterval(20) }
        #expect(!learned.isEmpty && !learned.contains { $0.bytesPerSecond == 0 })
        #expect(speeds.suffix(800).allSatisfy { $0 > 0.5 * rate && $0 < 1.8 * rate })
        #expect(approx(m.transfers[0].averageBytesPerSecond ?? 0, rate, rel: 0.05))
        #expect(approx(samples.map(\.bytesPerSecond).max() ?? 0, rate, rel: 0.05))   // peak from real samples
    }

    /// A real stall during a slow copy is still shown, but only after stallFactor x the learned
    /// interval (~7.5 s at a 2.5 s cadence, not 2 s), and the speed recovers at the next updates.
    @Test func realStallOnSlowCopyIsShownLateAndRecovers() {
        let rate = 3.4e6
        let before = Self.granularTicks(rate: rate, seconds: 40)
        let resumeAt = 60.0
        let after = Self.granularTicks(rate: rate, seconds: 40).map {
            Tick(tick: $0.tick + resumeAt, arrival: $0.arrival + resumeAt, bytes: before.last!.bytes + $0.bytes)
        }
        let (m, c) = makeMonitor()
        let start = c.now
        let (_, samples) = Self.displayed(before + after, monitor: m, clock: c, total: total)
        let lastBefore = start.addingTimeInterval(before.last!.arrival)
        let firstZero = samples.first { $0.bytesPerSecond == 0 }
        #expect(firstZero != nil)                                                  // the stall is shown...
        if let z = firstZero {
            let wait = z.time.timeIntervalSince(lastBefore)
            #expect(wait > 6 && wait < 9)                                         // ...after ~3 x 2.5 s
        }
        // After the resume, real rates come back (stall zeros are not in the median's history).
        let resumed = samples.filter { $0.time > start.addingTimeInterval(resumeAt + 8) }
        #expect(!resumed.isEmpty && resumed.allSatisfy { approx($0.bytesPerSecond, rate, rel: 0.3) })
        #expect(approx(m.transfers[0].bytesPerSecond, rate, rel: 0.3))
    }

    /// Two real 20 s pauses during a slow copy. The first must not be learned as a normal gap,
    /// or the second (threshold 1.5 x 20 s = 30 s) would never be shown.
    @Test func secondRealStallIsStillShown() {
        let rate = 3.4e6
        let seg = Self.granularTicks(rate: rate, seconds: 30)
        var ticks: [Tick] = []
        var offset = 0.0, base: Int64 = 0
        for _ in 0..<3 {                                     // copy 30 s, pause 20 s, x3
            ticks += seg.map { Tick(tick: $0.tick + offset, arrival: $0.arrival + offset, bytes: base + $0.bytes) }
            base = ticks.last!.bytes
            offset += 50
        }
        let (m, c) = makeMonitor()
        let start = c.now
        let (_, samples) = Self.displayed(ticks, monitor: m, clock: c, total: total)
        // Pauses run 30-50 s and 80-100 s (relative to the copy start).
        let firstPauseZeros = samples.filter { $0.bytesPerSecond == 0 && $0.time > start.addingTimeInterval(30) && $0.time < start.addingTimeInterval(50) }
        let secondPauseZeros = samples.filter { $0.bytesPerSecond == 0 && $0.time > start.addingTimeInterval(80) && $0.time < start.addingTimeInterval(100) }
        #expect(!firstPauseZeros.isEmpty)
        #expect(!secondPauseZeros.isEmpty)
        if let z = secondPauseZeros.first {
            #expect(z.time.timeIntervalSince(start.addingTimeInterval(80)) < 10)   // still ~3 x 2.5 s, not 30 s
        }
    }

    /// Window-text fallback at 3.4 MB/s: Finder's text moves in 10 MB steps, i.e. every ~3 s.
    @Test func slowWindowFallbackIsHeld() {
        let rate = 3.4e6
        let (m, c) = makeMonitor()
        let dest = URL(fileURLWithPath: "/V/dest")
        let p = finderProgress("/V/dest/testsrc")
        m.handlePublished(id: UUID(), progress: p, subscribedPath: dest.path)
        setBytes(p, 0, 2_000_000_000); m.poll()
        c.advance(0.5); setBytes(p, 30_000_000); m.poll()          // NSProgress then freezes (clone quirk)
        var speeds: [Double] = []
        for step in 1...1200 {                                    // 120 s
            c.advance(0.1)
            if step % 5 == 0 {
                let w = Int64(rate * Double(step) * 0.1) / 10_000_000 * 10_000_000 + 30_000_000
                m.noteWindowRow(destination: dest, bytesCompleted: w, bytesTotal: total, timestamp: c.now)
            }
            m.poll()
            if let t = m.transfers.first, t.usesWindowFallback, !t.isMeasuring { speeds.append(t.bytesPerSecond) }
        }
        let t = m.transfers[0]
        #expect(t.usesWindowFallback)
        let windowSamples = t.samples.filter { $0.bytesCompleted > 30_000_000 }
        #expect(!windowSamples.isEmpty && !windowSamples.contains { $0.bytesPerSecond == 0 })
        #expect(speeds.count > 500 && speeds.allSatisfy { $0 > 0.6 * rate && $0 < 1.5 * rate })
    }
}
