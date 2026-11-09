// Tests for TransferMonitor.noteWindowRow, the Finder-window byte count fallback (owner: athena).

import Foundation
import Testing
@testable import FinderSpeed

private let GB: Int64 = 1_000_000_000

/// Finder's window text has 10 MB resolution.
private func windowText(_ bytes: Int64) -> Int64 { bytes / 10_000_000 * 10_000_000 }

/// Runs `seconds` of simulated time in 0.1 s poll steps. NSProgress updates on ticks where
/// i % 5 == 0; the window row updates 0.1 s later (i % 5 == 1). So the window is "ahead" for
/// 0.4 s of every 0.5 s, as can happen in a normal copy.
@MainActor
private func simulate(_ m: TransferMonitor, _ c: FakeClock, seconds: Double,
                      ns: ((Double) -> Void)?, window: ((Double) -> Void)?) {
    let start = c.now
    for i in 1...Int((seconds * 10).rounded()) {
        c.advance(0.1)
        let t = c.now.timeIntervalSince(start)
        if i % 5 == 0 { ns?(t) }
        if i % 5 == 1 { window?(t) }
        m.poll()
    }
}

@Suite("Window fallback")
@MainActor
struct WindowFallbackTests {
    let dest = URL(fileURLWithPath: "/V/dest")

    @Test func normalCopyWithLeadingWindowNeverSwitches() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        publish(m, c, p, total: 20 * GB)
        let rate = 1e9   // fast enough that the window's lead (100 MB) is well above the tolerance
        simulate(m, c, seconds: 10,
                 ns: { t in setBytes(p, Int64((rate * t).rounded())) },
                 window: { t in
                     m.noteWindowRow(destination: dest, bytesCompleted: windowText(Int64((rate * t).rounded())), timestamp: c.now)
                 })
        let t = m.transfers[0]
        #expect(!t.usesWindowFallback)
        #expect(t.bytesTotal == 20 * GB)
        #expect(approx(t.bytesPerSecond, rate))
    }

    @Test func cloneQuirkSwitchesToWindowCountAndTotal() {
        // Apollo's case: Finder's NSProgress stops at the first file's size (its total too),
        // while the window keeps counting the real copy.
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/testsrc")
        publish(m, c, p, total: 2 * GB)
        let rate = 1e9
        simulate(m, c, seconds: 8,
                 ns: { t in setBytes(p, min(Int64((rate * t).rounded()), 2 * GB)) },
                 window: { t in
                     m.noteWindowRow(destination: self.dest, bytesCompleted: windowText(Int64((rate * t).rounded())),
                                     bytesTotal: 8 * GB, timestamp: c.now)
                 })
        let t = m.transfers[0]
        #expect(t.usesWindowFallback)
        #expect(t.bytesCompleted > 7 * GB)                         // not stuck at 2 GB
        #expect(t.bytesTotal == 8 * GB)                            // the window total replaces the bad one
        #expect(approx(t.bytesPerSecond, rate, rel: 0.05))
        // No spike and no dip when switching sources.
        #expect(t.samples.allSatisfy { $0.bytesPerSecond > 0.9 * rate && $0.bytesPerSecond < 1.1 * rate })
    }

    @Test func tooSmallTotalBecomesUnknownWithoutWindowTotal() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/testsrc")
        publish(m, c, p, total: 2 * GB)
        simulate(m, c, seconds: 6,
                 ns: { t in setBytes(p, min(Int64((1e9 * t).rounded()), 2 * GB)) },
                 window: { t in
                     m.noteWindowRow(destination: self.dest, bytesCompleted: windowText(Int64((1e9 * t).rounded())), timestamp: c.now)
                 })
        let t = m.transfers[0]
        #expect(t.usesWindowFallback)
        #expect(t.bytesTotal == 0)          // unknown rather than a wrong 2 GB
        #expect(t.fractionCompleted == 0)
    }

    @Test func stalledProgressUsesWindowThenWindowStallDecays() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        publish(m, c, p, total: 20 * GB)
        let rate = 0.5e9
        simulate(m, c, seconds: 6,
                 ns: { t in setBytes(p, min(Int64((rate * t).rounded()), 1 * GB)) },   // NSProgress freezes at 1 GB
                 window: { t in
                     m.noteWindowRow(destination: self.dest, bytesCompleted: windowText(Int64((rate * t).rounded())), timestamp: c.now)
                 })
        var t = m.transfers[0]
        #expect(t.usesWindowFallback)
        #expect(t.bytesTotal == 20 * GB)    // the NSProgress total was fine, so it is kept
        #expect(t.bytesCompleted >= 2_700_000_000)   // last window note at t=5.6 s
        #expect(approx(t.bytesPerSecond, rate, rel: 0.05))

        // Now the window count stops too: the speed decays to 0.
        simulate(m, c, seconds: 5, ns: nil, window: nil)
        t = m.transfers[0]
        #expect(t.samples.last!.bytesPerSecond == 0)
        #expect(t.bytesPerSecond < 0.05 * rate)
    }

    @Test func rowsAreMatchedByURLThenNameThenSoleTransfer() {
        let (m, c) = makeMonitor()
        publish(m, c, finderProgress("/V/a/x.bin"), total: 10 * GB)
        publish(m, c, finderProgress("/V/b/y.bin"), total: 10 * GB)
        func folder(_ name: String) -> Transfer { m.transfers.first { $0.destinationFolder.lastPathComponent == name }! }

        // Ambiguous (no URL, no name, two transfers): ignored.
        for _ in 0..<30 {
            c.advance(0.1)
            m.noteWindowRow(destination: nil, bytesCompleted: 5 * GB, timestamp: c.now)
            m.poll()
        }
        #expect(!folder("a").usesWindowFallback && !folder("b").usesWindowFallback)

        // By name: only b.
        for _ in 0..<30 {
            c.advance(0.1)
            m.noteWindowRow(destination: nil, destinationName: "b", bytesCompleted: 5 * GB, timestamp: c.now)
            m.poll()
        }
        #expect(!folder("a").usesWindowFallback && folder("b").usesWindowFallback)

        // By URL: a. An unknown destination is ignored.
        for _ in 0..<30 {
            c.advance(0.1)
            m.noteWindowRow(destination: URL(fileURLWithPath: "/V/a"), bytesCompleted: 5 * GB, timestamp: c.now)
            m.noteWindowRow(destination: URL(fileURLWithPath: "/V/zzz"), bytesCompleted: 9 * GB, timestamp: c.now)
            m.poll()
        }
        #expect(folder("a").usesWindowFallback)
        #expect(m.transfers.count == 2)
    }
}
