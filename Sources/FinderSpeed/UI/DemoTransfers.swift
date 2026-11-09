// UI/DemoTransfers.swift (owner: thor)
// Realistic synthetic Transfer values for Demo Mode and SwiftUI previews.

import Foundation

public enum DemoTransfers {

    /// Returns realistic fake transfers for demo mode:
    /// 1. An active 10.7 GB transfer at 29% (3.10 GB) with 60 samples covering 0...29% (~742 MB/s live).
    /// 2. A second transfer currently in the "Preparing…" phase.
    public static func make(now: Date = Date()) -> [Transfer] {
        let sampleCount = 60
        let sampleInterval: TimeInterval = 0.5
        let startTime = now.addingTimeInterval(-Double(sampleCount) * sampleInterval)
        let targetCompleted: Int64 = 3_100_000_000
        let totalBytes: Int64 = 10_700_000_000

        var rawSpeeds: [Double] = []
        rawSpeeds.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let progress = Double(i) / Double(sampleCount - 1)
            let ramp = min(1.0, Double(i + 1) / 5.0)
            let wave = sin(progress * .pi * 3.5) * 62_000_000 + cos(progress * .pi * 9.0) * 24_000_000
            let cacheDip = (i >= 34 && i <= 40) ? -145_000_000.0 : 0.0
            let rawSpeed = max(120_000_000, (715_000_000 * ramp) + wave + cacheDip)
            rawSpeeds.append(rawSpeed)
        }

        let speedSum = rawSpeeds.reduce(0, +)
        var cumulativeWeight: Double = 0
        var samples: [SpeedSample] = []
        samples.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let t = startTime.addingTimeInterval(Double(i + 1) * sampleInterval)
            let speed = rawSpeeds[i]
            cumulativeWeight += speed / speedSum
            let bytesDone: Int64
            if i == sampleCount - 1 {
                bytesDone = targetCompleted
            } else {
                bytesDone = max(1, Int64((Double(targetCompleted) * cumulativeWeight).rounded()))
            }
            samples.append(SpeedSample(time: t, bytesPerSecond: speed, bytesCompleted: bytesDone))
        }

        let avgSpeed = rawSpeeds.reduce(0, +) / Double(sampleCount)

        let activeTransfer = Transfer(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            destinationFolder: URL(fileURLWithPath: "/Volumes/FinderSpeedTest/ExternalSSD"),
            displayName: "Archive_2026.tar.zst",
            itemNames: ["Archive_2026.tar.zst"],
            bytesCompleted: targetCompleted,
            bytesTotal: totalBytes,
            bytesPerSecond: 742_000_000,
            samples: samples,
            isPreparing: false,
            startedAt: startTime,
            isFinished: false,
            finishedAt: nil,
            wasCancelled: false,
            averageBytesPerSecond: avgSpeed,
            usesWindowFallback: false
        )

        let preparingTransfer = Transfer(
            id: UUID(uuidString: "66666666-7777-8888-9999-000000000000")!,
            destinationFolder: URL(fileURLWithPath: "/Volumes/FinderSpeedTest/Backup"),
            displayName: "1,420 items",
            itemNames: ["Photos Library.photoslibrary", "Projects"],
            bytesCompleted: 0,
            bytesTotal: 0,
            bytesPerSecond: 0,
            samples: [],
            isPreparing: true,
            startedAt: now.addingTimeInterval(-1.5),
            isFinished: false,
            finishedAt: nil,
            wasCancelled: false,
            averageBytesPerSecond: nil,
            isMeasuring: false,
            usesWindowFallback: false
        )

        let measuringTransfer = Transfer(
            id: UUID(uuidString: "77777777-8888-9999-aaaa-bbbbbbbbbbbb")!,
            destinationFolder: URL(fileURLWithPath: "/Volumes/FinderSpeedTest/MediaDrive"),
            displayName: "RawFootage.mov",
            itemNames: ["RawFootage.mov"],
            bytesCompleted: 640_000_000,
            bytesTotal: 8_590_000_000,
            bytesPerSecond: 0,
            samples: [],
            isPreparing: false,
            startedAt: now.addingTimeInterval(-0.6),
            isFinished: false,
            finishedAt: nil,
            wasCancelled: false,
            averageBytesPerSecond: nil,
            isMeasuring: true,
            usesWindowFallback: false
        )

        return [activeTransfer, measuringTransfer, preparingTransfer]
    }
}
