// Replay of apollo's 2-row live test (spikes/window/PHASE3.md, observation 1; owner: athena).
//
// Two copies into different folders, 1 s apart. The panel briefly showed capture-a twice
// ("Speed: 0 KB/s · Average 337 MB/s" and "Average 0 KB/s · Peak 0 KB/s") with 679 MB copied.
// The engine never duplicated or replaced the transfer: 4 real runs with FINDERSPEED_ENGINE_LOG=1
// (fresh, repeated with pre-existing hint subscriptions, app launched 0.5 s and 3.5 s into the copies)
// show exactly one transfer per destination. Both rows match ONE late-attached transfer at two
// moments, drawn during the panel's 1 -> 2 row transition: before its first measurement it really
// reported speed 0 and no average. That part is fixed: `Transfer.isMeasuring` says "no estimate
// yet" instead of a fake 0.

import Foundation
import Testing
@testable import FinderSpeed

@Suite("Two-row replay (duplicate capture-a row)")
@MainActor
struct DupRowReplayTests {
    let rate = 300e6
    let total: Int64 = 8_590_229_504
    let destA = URL(fileURLWithPath: "/Volumes/FinderSpeedTest/capture-a")
    let destB = URL(fileURLWithPath: "/Volumes/FinderSpeedTest/capture-b")

    @Test func secondCopyNeverDuplicatesOrReplacesTheFirst() {
        let (m, c) = makeMonitor()
        let pA = finderProgress(destA.appendingPathComponent("real_8x1024m").path)
        let pB = finderProgress(destB.appendingPathComponent("real_8x1024m").path)
        // The same capture-a item delivered again by a second subscription (hints re-noting candidates
        // can subscribe the item folder itself): a second proxy for the same Finder progress.
        let pA2 = finderProgress(destA.appendingPathComponent("real_8x1024m").path)
        var idA: UUID?
        var everMeasuring = false

        // 0.1 s steps. Finder ticks every 0.5 s. The hint subscription for capture-a delivers A
        // mid-copy (679 MB, late attach); B starts 1 s later and is delivered at its first byte.
        for step in 1...200 {
            c.advance(0.1)
            let t = Double(step) * 0.1
            let bytesA = Int64(679_500_000 + rate * t)
            let bytesB = t >= 1.0 ? Int64(rate * (t - 1.0)) : -1
            if step == 1 {
                setBytes(pA, bytesA, total)
                m.handlePublished(id: UUID(), progress: pA, subscribedPath: destA.path)
            }
            if step == 10 { m.handlePublished(id: UUID(), progress: pB, subscribedPath: destB.path) }
            if step == 15 {
                setBytes(pA2, bytesA, total)
                m.handlePublished(id: UUID(), progress: pA2, subscribedPath: destA.appendingPathComponent("real_8x1024m").path)
            }
            if step % 5 == 0 {
                setBytes(pA, bytesA, total)
                if step >= 15 { setBytes(pA2, bytesA, total) }
                if step >= 10 { setBytes(pB, max(bytesB, 0), total) }
                // Window rows, summed per destination as App/PanelWiring does. capture-b's name is
                // resolved by the hints ~1.5 s after its row appears; until then it is matched by name.
                m.noteWindowRow(destination: destA, destinationName: "capture-a",
                                bytesCompleted: bytesA / 10_000_000 * 10_000_000, bytesTotal: total, timestamp: c.now)
                if step >= 12 {
                    m.noteWindowRow(destination: step >= 27 ? destB : nil, destinationName: "capture-b",
                                    bytesCompleted: max(bytesB, 0) / 10_000_000 * 10_000_000, bytesTotal: total, timestamp: c.now)
                }
            }
            m.poll()

            // At every step: at most one transfer per destination, and capture-a keeps its identity.
            let a = m.transfers.filter { $0.destinationFolder.path == destA.path }
            let b = m.transfers.filter { $0.destinationFolder.path == destB.path }
            #expect(a.count <= 1 && b.count <= 1, "step \(step): \(m.transfers.map(\.destinationDisplayName))")
            if let ta = a.first {
                if let idA { #expect(ta.id == idA, "capture-a was replaced at step \(step)") } else { idA = ta.id }
                // No fake "0 KB/s": while copying, either there is a speed or the transfer says it is measuring.
                if !ta.isFinished && !ta.isPreparing {
                    #expect(ta.isMeasuring || ta.bytesPerSecond > 0, "step \(step): speed 0 without isMeasuring")
                    everMeasuring = everMeasuring || ta.isMeasuring
                }
            }
        }
        #expect(everMeasuring)                                       // the late attach starts out measuring...
        let a = m.transfers.first { $0.destinationFolder.path == destA.path }!
        #expect(!a.isMeasuring && approx(a.bytesPerSecond, rate, rel: 0.1))   // ...then reads the real speed
        #expect(!a.usesWindowFallback)                                // the second row never leaked into capture-a
        #expect(m.transfers.count == 2)
        #expect(a.bytesCompleted < total)                             // capture-a not double counted
        #expect(a.itemNames == ["real_8x1024m"])
    }

    @Test func measuringEndsWithinAboutOneSecondOfLateAttach() {
        let (m, c) = makeMonitor()
        let p = finderProgress(destA.appendingPathComponent("real_8x1024m").path, bytes: 679 * MB, total: total)
        m.handlePublished(id: UUID(), progress: p, subscribedPath: destA.path)
        m.poll()
        #expect(m.transfers[0].isMeasuring)
        #expect(m.transfers[0].averageBytesPerSecond == nil)
        var b: Int64 = 679 * MB
        var measuredAfter: Double?
        for i in 1...10 {
            b = copy(m, c, p, from: b, bytesPerSecond: rate, seconds: 0.5)
            if !m.transfers[0].isMeasuring { measuredAfter = Double(i) * 0.5; break }
        }
        #expect((measuredAfter ?? 99) <= 1.0)
        #expect(approx(m.transfers[0].bytesPerSecond, rate, rel: 0.1))
    }
}
