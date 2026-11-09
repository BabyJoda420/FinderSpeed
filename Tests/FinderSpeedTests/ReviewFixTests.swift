// Regression tests for apollo's engine review (spikes/window/ENGINE_REVIEW.md), owner: athena.

import Foundation
import Testing
@testable import FinderSpeed

private let GB: Int64 = 1_000_000_000

@Suite("Engine review fixes")
@MainActor
struct ReviewFixTests {
    let dest = URL(fileURLWithPath: "/V/dest")

    // #2: short segments roll into the next one; the short final segment is not a spike.
    @Test func shortSegmentsAreFoldedNotSpiked() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        let id = publish(m, c, p, total: 10 * GB)
        var b = copy(m, c, p, from: 0, bytesPerSecond: 100e6, seconds: 3)
        let n = m.transfers[0].samples.count

        // A change only 0.1 s after the last one: no sample yet...
        c.advance(0.1); b += 10 * MB; setBytes(p, b); m.poll()
        #expect(m.transfers[0].samples.count == n)
        // ...its bytes land in the next sample (0.5 s, 50 MB in total), nothing is lost.
        c.advance(0.4); b += 40 * MB; setBytes(p, b); m.poll()
        #expect(m.transfers[0].samples.count == n + 1)
        #expect(approx(m.transfers[0].samples.last!.bytesPerSecond, 100e6))

        // The final update arrives 0.4 s later with a lagged chunk (would read 150 MB/s): a partial
        // final segment is not sampled (real run: 0.38 s final segment read +25 %).
        c.advance(0.4); setBytes(p, b + 60 * MB)
        m.handleUnpublished(id: id)
        let t = m.transfers[0]
        #expect(t.isFinished)
        #expect(t.samples.count == n + 1)
        #expect(t.samples.allSatisfy { approx($0.bytesPerSecond, 100e6) })
        #expect(t.bytesCompleted == b + 60 * MB)
    }

    // #2 (follow-on): Finder's completing update carries a catch-up burst on a normal 0.5 s
    // segment (real 4 GB folder copy: ... 904, 971, 1290 MB/s). It is counted but not graphed.
    @Test func completingUpdateBurstIsNotGraphed() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        let id = publish(m, c, p, total: 1000 * MB)
        let b = copy(m, c, p, from: 0, bytesPerSecond: 100e6, seconds: 9)     // 900 MB
        let n = m.transfers[0].samples.count
        for _ in 0..<4 { c.advance(0.1); m.poll() }
        c.advance(0.1); setBytes(p, 1000 * MB); m.poll()                        // +100 MB in 0.5 s... 
        #expect(b == 900 * MB)
        #expect(m.transfers[0].samples.count == n)                              // ...not graphed
        #expect(m.transfers[0].bytesCompleted == 1000 * MB)
        c.advance(0.2); m.handleUnpublished(id: id)
        let t = m.transfers[0]
        #expect(t.isFinished && !t.wasCancelled)
        #expect(t.samples.allSatisfy { approx($0.bytesPerSecond, 100e6) })
        #expect(approx(t.averageBytesPerSecond ?? 0, 1000e6 / 9.7, rel: 0.05))  // 9 s + 0.5 + 0.2: the average still counts it
    }

    // Phase 3: the first value after preparing can arrive late and carry several ticks at once.
    // It only starts the rate history; timing it as "one tick" read 3x in the replays.
    @Test func lateFirstValueAfterPreparingDoesNotSpike() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/folder")
        publish(m, c, p, total: 10 * GB)                          // counter just went -1 -> 0
        c.advance(1.5); setBytes(p, 150 * MB); m.poll()           // 3 ticks delivered together
        _ = copy(m, c, p, from: 150 * MB, bytesPerSecond: 100e6, seconds: 3)
        let s = m.transfers[0].samples
        #expect(!s.isEmpty)
        #expect(s.allSatisfy { approx($0.bytesPerSecond, 100e6) })
    }

    // #3: a stalled copy whose window text rounds up by half a step (100 MB steps at ~123 GB)
    // must not switch to the window count.
    @Test func roundedWindowTextOnLargeCopyDoesNotSwitch() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/huge.bin")
        publish(m, c, p, total: 500 * GB)
        setBytes(p, 123_450_000_000); c.advance(0.5); m.poll()   // then NSProgress stalls...
        for _ in 0..<60 {                                         // ...and the window shows "123.5 GB"
            c.advance(0.1)
            m.noteWindowRow(destination: dest, bytesCompleted: 123_500_000_000, timestamp: c.now)
            m.poll()
        }
        #expect(!m.transfers[0].usesWindowFallback)
        #expect(m.transfers[0].bytesCompleted == 123_450_000_000)
    }

    /// Apollo's clone case: NSProgress freezes at 2 GB of 2 GB while the window counts on to `upTo`.
    @MainActor
    private func cloneQuirkCopy(_ m: TransferMonitor, _ c: FakeClock, upTo: Int64, windowTotal: Int64) -> UUID {
        let p = finderProgress("/V/dest/testsrc")
        let id = publish(m, c, p, total: 2 * GB)
        let start = c.now
        var last: Int64 = 0
        for i in 1...200 {
            c.advance(0.1)
            let trueBytes = min(Int64((1e9 * c.now.timeIntervalSince(start)).rounded()), upTo)
            if i % 5 == 0 { setBytes(p, min(trueBytes, 2 * GB)) }
            if i % 5 == 1 {
                m.noteWindowRow(destination: dest, bytesCompleted: trueBytes / 10_000_000 * 10_000_000,
                                bytesTotal: windowTotal, timestamp: c.now)
            }
            m.poll()
            if trueBytes == upTo && last == upTo { break }
            last = trueBytes
        }
        return id
    }

    // #5: cancel detection while in window-fallback mode.
    @Test func cancelIsDetectedInFallbackMode() {
        let (m, c) = makeMonitor()
        let id = cloneQuirkCopy(m, c, upTo: 4 * GB, windowTotal: 8 * GB)   // user stops at 4 of 8 GB
        #expect(m.transfers[0].usesWindowFallback)
        m.handleUnpublished(id: id)
        #expect(m.transfers[0].isFinished)
        #expect(m.transfers[0].wasCancelled)
    }

    @Test func completedCopyInFallbackModeIsNotCancelled() {
        let (m, c) = makeMonitor()
        // Finder finished, but the last window text we read before the row closed was "7.6 of 8 GB"
        // (it can lag the end by a tick or two at ~1 GB/s). Must not read as cancelled.
        let id = cloneQuirkCopy(m, c, upTo: 7_600_000_000, windowTotal: 8 * GB)
        #expect(m.transfers[0].usesWindowFallback)
        m.handleUnpublished(id: id)
        #expect(m.transfers[0].isFinished)
        #expect(!m.transfers[0].wasCancelled)
    }

    // #7: unwatching the folder that delivered a running copy must not mark it cancelled.
    @Test func unwatchMidCopyWithoutOtherSubscriptionRemovesTransferQuietly() {
        let (m, c) = makeMonitor()
        m.watch(folder: dest)
        let p = finderProgress("/V/dest/big.bin")
        m.handlePublished(id: UUID(), progress: p, subscribedPath: "/V/dest")
        c.advance(0.1); setBytes(p, 0, 10 * GB); m.poll()
        _ = copy(m, c, p, from: 0, bytesPerSecond: 100e6, seconds: 2)
        m.unwatch(folder: dest)
        #expect(m.transfers.isEmpty)                       // not shown as FINISHED or CANCELLED
        #expect(!m.watchedFolders.contains(dest))
    }

    @Test func unwatchMidCopyPromotesDuplicateFromOtherSubscription() {
        let (m, c) = makeMonitor()
        m.watch(folder: dest)
        let viaParent = finderProgress("/V/dest/multi")
        let viaItem = finderProgress("/V/dest/multi")      // same item, delivered by a 2nd subscription
        m.handlePublished(id: UUID(), progress: viaParent, subscribedPath: "/V/dest")
        m.handlePublished(id: UUID(), progress: viaItem, subscribedPath: "/V/dest/multi")
        c.advance(0.1); setBytes(viaParent, 0, 10 * GB); setBytes(viaItem, 0, 10 * GB); m.poll()
        var b: Int64 = 0
        for _ in 0..<4 {   // both proxies see the same Finder counter
            c.advance(0.5); b += 50 * MB; setBytes(viaParent, b); setBytes(viaItem, b); m.poll()
        }
        m.unwatch(folder: dest)
        #expect(m.transfers.count == 1)
        #expect(!m.transfers[0].isFinished)
        let n = m.transfers[0].samples.count
        _ = copy(m, c, viaItem, from: b, bytesPerSecond: 100e6, seconds: 2)   // only the item proxy updates now
        let t = m.transfers[0]
        #expect(t.bytesCompleted == b + 200 * MB)
        #expect(t.samples.count == n + 4)
        #expect(t.samples.allSatisfy { approx($0.bytesPerSecond, 100e6) })   // no gap spike at the handover
    }

    // #7 with a REAL subscription: Foundation calls our unpublish handler synchronously inside
    // removeSubscriber. That must not finish/cancel the copy (the fake-handle tests above can't
    // exercise this path).
    @Test func unwatchWithRealSubscriptionDoesNotCancel() async throws {
        let m = TransferMonitor()
        m.autoPoll = false
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("athena-unwatch-\(UUID().uuidString)", isDirectory: true)
        let p = finderProgress(folder.appendingPathComponent("big.bin").path, bytes: 0, total: 10 * GB)
        p.publish()
        defer { p.unpublish() }
        m.watch(folder: folder)
        for _ in 0..<40 where m.transfers.isEmpty {      // delivery goes through Foundation
            try await Task.sleep(nanoseconds: 50_000_000)
            m.poll()
        }
        try #require(m.transfers.count == 1, "progress was not delivered in-process")
        setBytes(p, 1 * GB)
        m.unwatch(folder: folder)
        #expect(m.transfers.isEmpty)                      // gone quietly, not FINISHED/CANCELLED
    }

    // #8: a transfer revived by a second drag starts from the new speed, not from 0.
    @Test func revivedTransferDoesNotRampFromZero() {
        let (m, c) = makeMonitor()
        let p1 = finderProgress("/V/dest/a.bin")
        let id1 = publish(m, c, p1, total: 300 * MB)
        _ = copy(m, c, p1, from: 0, bytesPerSecond: 100e6, seconds: 3)
        m.handleUnpublished(id: id1)
        #expect(m.transfers[0].isFinished)

        c.advance(0.3)                                      // within reviveWindow
        let p2 = finderProgress("/V/dest/b.bin")
        publish(m, c, p2, total: 1 * GB)
        var b = copy(m, c, p2, from: 0, bytesPerSecond: 200e6, seconds: 1.0)
        #expect(m.transfers.count == 1)
        #expect(!m.transfers[0].isFinished)
        #expect(approx(m.transfers[0].bytesPerSecond, 200e6))   // provisional, before the first windowed sample
        let n = m.transfers[0].samples.count
        while m.transfers[0].samples.count == n { b = copy(m, c, p2, from: b, bytesPerSecond: 200e6, seconds: 0.5) }
        #expect(approx(m.transfers[0].bytesPerSecond, 200e6))   // EMA restarted from the first new sample
    }

    // #6: subscriptions made before start() are removed by stop().
    @Test func stopCleansUpEvenIfNeverStarted() {
        let (m, _) = makeMonitor()
        m.watch(folder: dest)
        m.noteFinderDestination(URL(fileURLWithPath: "/V/other"))
        #expect(m.watchedFolders.count == 2)
        m.stop()
        #expect(m.watchedFolders.isEmpty)
    }
}
