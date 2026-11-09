// SpeedSample.bytesCompleted: cumulative bytes at the end of each sample (x-axis in percent complete).

import Foundation
import Testing
@testable import FinderSpeed

@Suite("Sample bytesCompleted")
@MainActor
struct SampleBytesTests {
    @Test func nsProgressSamplesCarryCumulativeBytes() {
        let (m, c) = makeMonitor()
        let p = finderProgress("/V/dest/big.bin")
        publish(m, c, p, total: 1000 * MB)
        var seen: [Int64] = []
        var b: Int64 = 0
        for _ in 0..<10 {
            b = copy(m, c, p, from: b, bytesPerSecond: 100e6, seconds: 0.5)
            if let last = m.transfers[0].samples.last, last.time == c.now { seen.append(last.bytesCompleted) }
            if let last = m.transfers[0].samples.last, last.time == c.now {
                #expect(last.bytesCompleted == m.transfers[0].bytesCompleted)   // value at the sample's end
            }
        }
        let s = m.transfers[0].samples
        #expect(!seen.isEmpty)
        #expect(zip(s, s.dropFirst()).allSatisfy { $0.bytesCompleted <= $1.bytesCompleted })
        #expect(s.last!.bytesCompleted == b)
        // Stall zeros also carry the (unchanged) cumulative bytes.
        for _ in 0..<40 { c.advance(0.1); m.poll() }
        #expect(m.transfers[0].samples.last!.bytesPerSecond == 0)
        #expect(m.transfers[0].samples.last!.bytesCompleted == b)
    }

    @Test func windowFallbackSamplesCarryWindowBytes() {
        let (m, c) = makeMonitor()
        let dest = URL(fileURLWithPath: "/V/dest")
        let p = finderProgress("/V/dest/testsrc")
        publish(m, c, p, total: 2 * 1_000_000_000)
        setBytes(p, 50 * MB); c.advance(0.5); m.poll()                 // NSProgress then freezes
        var w: Int64 = 50 * MB
        for i in 1...60 {
            c.advance(0.1)
            if i % 5 == 0 { w += 50 * MB; m.noteWindowRow(destination: dest, bytesCompleted: w, bytesTotal: 4_000_000_000, timestamp: c.now) }
            m.poll()
        }
        let t = m.transfers[0]
        #expect(t.usesWindowFallback)
        let windowSamples = t.samples.filter { $0.bytesCompleted > 50 * MB }
        #expect(!windowSamples.isEmpty)
        #expect(t.samples.last!.bytesCompleted == w)                    // the window count, not NSProgress
        #expect(t.samples.last!.bytesCompleted == t.bytesCompleted)
    }

    @Test func existingInitStillCompilesWithDefault() {
        let s = SpeedSample(time: Date(), bytesPerSecond: 1)
        #expect(s.bytesCompleted == 0)
    }
}
