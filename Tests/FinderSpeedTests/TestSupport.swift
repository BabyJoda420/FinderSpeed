// Shared helpers for the Engine tests (owner: athena).

import Foundation
@testable import FinderSpeed

let MB: Int64 = 1_000_000

// MARK: Helpers

final class FakeClock {
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

/// A Progress shaped like the ones Finder publishes (see spikes/progress/REPORT.md).
func finderProgress(_ itemPath: String, bytes: Int64 = -1, total: Int64 = -1) -> Progress {
    let p = Progress(totalUnitCount: 1000)
    p.kind = .file
    p.fileOperationKind = .copying
    p.fileURL = URL(fileURLWithPath: itemPath)
    p.setUserInfoObject(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                        forKey: ProgressUserInfoKey("FIOperationUUID"))
    setBytes(p, bytes, total)
    return p
}

func setBytes(_ p: Progress, _ done: Int64, _ total: Int64? = nil) {
    p.setUserInfoObject(NSNumber(value: done), forKey: ProgressUserInfoKey("NSProgressByteCompletedCountKey"))
    if let total {
        p.setUserInfoObject(NSNumber(value: total), forKey: ProgressUserInfoKey("NSProgressByteTotalCountKey"))
    }
}

@MainActor
func makeMonitor() -> (TransferMonitor, FakeClock) {
    let m = TransferMonitor()
    let c = FakeClock()
    m.autoPoll = false
    m.clock = { c.now }
    return (m, c)
}

/// Publishes `p` and runs the "preparing" phase: -1 -> 0, at Finder's cadence.
@MainActor
@discardableResult
func publish(_ m: TransferMonitor, _ c: FakeClock, _ p: Progress, total: Int64) -> UUID {
    let id = UUID()
    m.handlePublished(id: id, progress: p, subscribedPath: (p.fileURL!.deletingLastPathComponent().path))
    m.poll()
    c.advance(0.1); setBytes(p, 0, total); m.poll()
    return id
}

/// Simulates Finder copying at a constant speed: the counter moves every 0.5 s and is polled every 0.1 s.
@MainActor
func copy(_ m: TransferMonitor, _ c: FakeClock, _ p: Progress,
                  from start: Int64, bytesPerSecond: Double, seconds: Double) -> Int64 {
    var bytes = start
    let ticks = Int((seconds / 0.5).rounded())
    for _ in 0..<ticks {
        for _ in 0..<4 { c.advance(0.1); m.poll() }   // no change between Finder updates
        c.advance(0.1)
        bytes += Int64(bytesPerSecond * 0.5)
        setBytes(p, bytes)
        m.poll()
    }
    return bytes
}

func approx(_ a: Double, _ b: Double, rel: Double = 0.02) -> Bool {
    abs(a - b) <= abs(b) * rel + 1e-9
}
