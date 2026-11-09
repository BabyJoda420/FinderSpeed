// Tests for Engine/ (owner: athena). Run with `swift test`.
//
// They drive TransferMonitor directly: fake Finder-style Progress objects are fed to
// handlePublished/handleUnpublished, the clock is faked, and poll() is called by hand.
// No real subscriptions, timers or Finder involved.

import Foundation
import Testing
@testable import FinderSpeed

// MARK: Speed math

@Suite("SpeedMath")
struct SpeedMathTests {
    @Test func emaStepUsesTimeAwareAlpha() {
        // dt == tau gives alpha = 1 - 1/e
        let v = SpeedMath.emaStep(previous: 0, sample: 100, dt: 1.5, timeConstant: 1.5)
        #expect(approx(v, 100 * (1 - exp(-1))))
        // dt == 0 leaves the value unchanged; a very long dt converges to the sample.
        #expect(SpeedMath.emaStep(previous: 42, sample: 100, dt: 0, timeConstant: 1.5) == 42)
        #expect(approx(SpeedMath.emaStep(previous: 0, sample: 100, dt: 60, timeConstant: 1.5), 100))
        // Negative dt is clamped (no extrapolation).
        #expect(SpeedMath.emaStep(previous: 42, sample: 100, dt: -1, timeConstant: 1.5) == 42)
    }

    @Test func rateIsNeverNegativeOrInfinite() {
        #expect(SpeedMath.rate(bytes: 50 * MB, seconds: 0.5) == 100e6)
        #expect(SpeedMath.rate(bytes: -5, seconds: 0.5) == 0)
        #expect(SpeedMath.rate(bytes: 5, seconds: 0) == 0)
    }
}

// MARK: TransferMonitor

@Suite("TransferMonitor")
@MainActor
struct TransferMonitorTests {

    @Test func preparingUntilFirstRealBytes() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")          // bytes -1 / total -1
        m.handlePublished(id: UUID(), progress: p, subscribedPath: "/V/dest")
        m.poll()
        #expect(m.transfers.count == 1)
        #expect(m.transfers[0].isPreparing)
        #expect(m.transfers[0].bytesCompleted == 0)

        c.advance(0.1); setBytes(p, 0, 1000 * MB); m.poll()
        #expect(m.transfers[0].isPreparing)
        #expect(m.transfers[0].bytesTotal == 1000 * MB)
        #expect(m.transfers[0].samples.isEmpty)

        c.advance(0.5); setBytes(p, 50 * MB); m.poll()
        #expect(!m.transfers[0].isPreparing)
        // The first value only starts the rate history; samples follow once it spans rawRateWindow.
        #expect(m.transfers[0].samples.isEmpty)
        _ = copy(m, c, p, from: 50 * MB, bytesPerSecond: 100e6, seconds: 1.5)
        #expect(!m.transfers[0].samples.isEmpty)
    }

    @Test func longPreparingDoesNotDiluteSpeedOrAverage() {
        // Folder copies sit at 0 bytes for seconds while Finder prepares. Those seconds must not
        // dilute the samples, nor the average (the first bytes arrived within ~one 0.5 s tick).
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/folder")
        publish(m, c, p, total: 1000 * MB)
        c.advance(3.0); setBytes(p, 50 * MB); m.poll()
        _ = copy(m, c, p, from: 50 * MB, bytesPerSecond: 100e6, seconds: 3)
        let t = m.transfers[0]
        #expect(!t.samples.isEmpty)
        #expect(t.samples.allSatisfy { approx($0.bytesPerSecond, 100e6) })
        #expect(approx(t.bytesPerSecond, 100e6))
        #expect(approx(t.averageBytesPerSecond ?? 0, 100e6))
    }

    @Test func emaTracksConstantSpeedAndFollowsAStep() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        publish(m, c, p, total: 10_000 * MB)
        var b = copy(m, c, p, from: 0, bytesPerSecond: 100e6, seconds: 5)
        #expect(approx(m.transfers[0].bytesPerSecond, 100e6))
        #expect(m.transfers[0].samples.allSatisfy { approx($0.bytesPerSecond, 100e6) })

        // Speed doubles: the EMA moves smoothly (no jump) and converges within a few seconds.
        b = copy(m, c, p, from: b, bytesPerSecond: 200e6, seconds: 0.5)
        let afterOne = m.transfers[0].bytesPerSecond
        #expect(afterOne > 100e6 && afterOne < 190e6)
        // Raw samples cover rawRateWindow (1.5 s): they reach the new speed once the window has
        // only post-step history, and never overshoot on the way.
        b = copy(m, c, p, from: b, bytesPerSecond: 200e6, seconds: 1.5)
        #expect(approx(m.transfers[0].samples.last!.bytesPerSecond, 200e6))
        #expect(m.transfers[0].samples.allSatisfy { $0.bytesPerSecond <= 200e6 * 1.02 })
        _ = copy(m, c, p, from: b, bytesPerSecond: 200e6, seconds: 8)
        #expect(approx(m.transfers[0].bytesPerSecond, 200e6))
    }

    @Test func stallDecaysSpeedTowardZero() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        publish(m, c, p, total: 10_000 * MB)
        _ = copy(m, c, p, from: 0, bytesPerSecond: 100e6, seconds: 3)
        for _ in 0..<60 { c.advance(0.1); m.poll() }   // 6 s without a counter change
        let t = m.transfers[0]
        #expect(t.samples.last!.bytesPerSecond == 0)
        #expect(t.bytesPerSecond < 10e6)
    }

    @Test func twoProgressesWithSameParentAreOneTransfer() {
        let (m, c) = makeMonitor()
        let a = finderProgress("/V/dest/multi")
        let b = finderProgress("/V/dest/big.bin")
        let ida = publish(m, c, a, total: 1000 * MB)
        let idb = publish(m, c, b, total: 2000 * MB)
        #expect(m.transfers.count == 1)
        let t = m.transfers[0]
        #expect(t.destinationFolder.path == "/V/dest")
        #expect(t.itemNames == ["multi", "big.bin"])
        #expect(t.displayName == "2 items")
        #expect(t.bytesTotal == 3000 * MB)

        // Finder copies them one after the other; bytes are summed.
        _ = copy(m, c, a, from: 0, bytesPerSecond: 100e6, seconds: 10)
        m.handleUnpublished(id: ida)
        #expect(!m.transfers[0].isFinished)                // b is still pending
        _ = copy(m, c, b, from: 0, bytesPerSecond: 100e6, seconds: 2)
        #expect(m.transfers[0].bytesCompleted == 1000 * MB + 200 * MB)
        #expect(approx(m.transfers[0].bytesPerSecond, 100e6, rel: 0.05))   // no spike at the handoff
        _ = idb
    }

    @Test func differentParentsAreSeparateTransfers() {
        let (m, c) = makeMonitor()
        publish(m, c, finderProgress("/V/one/a.bin"), total: 10 * MB)
        publish(m, c, finderProgress("/V/two/b.bin"), total: 10 * MB)
        #expect(Set(m.transfers.map(\.destinationFolder.path)) == ["/V/one", "/V/two"])
    }

    @Test func sameItemSeenTwiceIsCountedOnce() {
        // e.g. subscribed to both the item and its parent folder.
        let (m, c) = makeMonitor()
        let p1 = finderProgress("/V/dest/multi")
        let p2 = finderProgress("/V/dest/multi")
        publish(m, c, p1, total: 100 * MB)
        publish(m, c, p2, total: 100 * MB)
        #expect(m.transfers.count == 1)
        #expect(m.transfers[0].bytesTotal == 100 * MB)
        #expect(m.transfers[0].itemNames == ["multi"])
    }

    @Test func nonFinderProgressIsIgnored() {
        // Seen in the wild: a media app's 50/100 progress on a .mkv, with no byte keys.
        let (m, c) = makeMonitor()
        let p = Progress(totalUnitCount: 100)
        p.kind = .file
        p.fileURL = URL(fileURLWithPath: "/Users/x/Movies/film.mkv")
        p.completedUnitCount = 50
        m.handlePublished(id: UUID(), progress: p, subscribedPath: "/Users/x/Movies")
        for _ in 0..<40 { c.advance(0.1); m.poll() }
        #expect(m.transfers.isEmpty)
    }

    @Test func finishedTransferLingersWithAverageThenIsRemoved() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        let id = publish(m, c, p, total: 500 * MB)
        _ = copy(m, c, p, from: 0, bytesPerSecond: 100e6, seconds: 5)
        m.handleUnpublished(id: id)
        var t = m.transfers[0]
        #expect(t.isFinished)
        #expect(!t.wasCancelled)
        #expect(t.finishedAt == c.now)
        #expect(t.bytesPerSecond == 0)
        #expect(approx(t.averageBytesPerSecond ?? 0, 100e6, rel: 0.05))

        c.advance(m.finishedLinger - 0.5); m.poll()
        t = m.transfers[0]
        #expect(t.isFinished)                               // still visible during linger
        c.advance(1.0); m.poll()
        #expect(m.transfers.isEmpty)
    }

    @Test func unpublishedShortOfTotalIsCancelled() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        let id = publish(m, c, p, total: 2000 * MB)
        _ = copy(m, c, p, from: 0, bytesPerSecond: 100e6, seconds: 2)   // 200 of 2000 MB
        m.handleUnpublished(id: id)
        #expect(m.transfers[0].isFinished)
        #expect(m.transfers[0].wasCancelled)
    }

    @Test func progressMarkedCancelledIsCancelled() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        let id = publish(m, c, p, total: 100 * MB)
        setBytes(p, 100 * MB); c.advance(0.5); m.poll()
        p.cancel()
        m.handleUnpublished(id: id)
        #expect(m.transfers[0].wasCancelled)
    }

    @Test func sampleCapKeepsNewestSamples() {
        let (m, c) = makeMonitor()
        m.sampleCap = 50
        let p = finderProgress("/V/dest/big.bin")
        publish(m, c, p, total: 100_000 * MB)
        _ = copy(m, c, p, from: 0, bytesPerSecond: 100e6, seconds: 60)   // 120 counter updates
        let s = m.transfers[0].samples
        #expect(s.count == 50)
        #expect(s.last!.time == c.now)
        #expect(zip(s, s.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func lateAttachDoesNotSpike() {
        // Engine starts while 1 GB is already copied: neither the first observed value nor the first
        // change after it (the proxy's first value can be stale) may be turned into a speed sample.
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin", bytes: 1000 * MB, total: 2000 * MB)
        m.handlePublished(id: UUID(), progress: p, subscribedPath: "/V/dest")
        m.poll()
        #expect(m.transfers[0].samples.isEmpty)
        #expect(!m.transfers[0].isPreparing)
        // We attached mid-tick: Finder's next update lands only 0.1 s later but carries a full
        // 0.5 s of bytes. Timing it from the attach would read 500 MB/s.
        c.advance(0.1); setBytes(p, 1050 * MB); m.poll()
        #expect(m.transfers[0].samples.isEmpty)
        _ = copy(m, c, p, from: 1050 * MB, bytesPerSecond: 100e6, seconds: 3)
        let s = m.transfers[0].samples
        #expect(!s.isEmpty)
        #expect(s.allSatisfy { approx($0.bytesPerSecond, 100e6) })
    }
}
