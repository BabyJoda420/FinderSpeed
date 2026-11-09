// UI/SpeedGraphView.swift (owner: thor)
// Swift Charts throughput graph in Finder's text column (width 311, height 64, no box or border).
// Uses percent-complete (0...1) on the X-axis when bytesTotal and sample.bytesCompleted are known,
// so the curve's right edge aligns with Finder's progress bar fill above it; falls back to time otherwise.

import Charts
import SwiftUI

public struct SpeedGraphView: View {
    public let samples: [SpeedSample]
    public var bytesTotal: Int64
    public var averageBytesPerSecond: Double?
    public var maxWindowSeconds: TimeInterval
    public var chartHeight: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(
        samples: [SpeedSample],
        bytesTotal: Int64 = 0,
        averageBytesPerSecond: Double? = nil,
        maxWindowSeconds: TimeInterval = 120,
        chartHeight: CGFloat = 64
    ) {
        self.samples = samples
        self.bytesTotal = bytesTotal
        self.averageBytesPerSecond = averageBytesPerSecond
        self.maxWindowSeconds = maxWindowSeconds
        self.chartHeight = chartHeight
    }

    public init(
        transfer: Transfer,
        maxWindowSeconds: TimeInterval = 120,
        chartHeight: CGFloat = 64
    ) {
        self.init(
            samples: transfer.samples,
            bytesTotal: transfer.bytesTotal,
            averageBytesPerSecond: SpeedFormatting.effectiveAverageSpeed(for: transfer),
            maxWindowSeconds: maxWindowSeconds,
            chartHeight: chartHeight
        )
    }

    private struct TimePlotPoint: Identifiable {
        let id: Int
        let time: Date
        let mbPerSecond: Double
    }

    private struct PercentPlotPoint: Identifiable {
        let id: Int
        let fraction: Double
        let mbPerSecond: Double
    }

    /// True when `bytesTotal` is known (> 0) and every sample carries a positive `bytesCompleted`.
    private var usesPercentAxis: Bool {
        bytesTotal > 0 && !samples.isEmpty && samples.allSatisfy { $0.bytesCompleted > 0 }
    }

    /// Samples mapped to `0...1` fraction complete when `usesPercentAxis` is true.
    private var percentPoints: [PercentPlotPoint] {
        guard usesPercentAxis else { return [] }
        let total = Double(bytesTotal)
        var result: [PercentPlotPoint] = []
        result.reserveCapacity(samples.count + 1)

        if let first = samples.first {
            let firstFrac = min(1.0, max(0.0, Double(first.bytesCompleted) / total))
            let firstMBps = max(0, first.bytesPerSecond) / 1_000_000
            if firstFrac > 0.0001 {
                result.append(PercentPlotPoint(id: 0, fraction: 0.0, mbPerSecond: firstMBps))
            }
        }

        var lastFraction: Double = -1.0
        for (idx, sample) in samples.enumerated() {
            var frac = min(1.0, max(0.0, Double(sample.bytesCompleted) / total))
            if frac <= lastFraction {
                frac = min(1.0, lastFraction + 0.00001)
            }
            lastFraction = frac
            let mbps = max(0, sample.bytesPerSecond) / 1_000_000
            result.append(PercentPlotPoint(id: idx + 1, fraction: frac, mbPerSecond: mbps))
        }
        return result
    }

    /// Fallback: samples trimmed to the last `maxWindowSeconds` (default 120 s), converted to decimal MB/s.
    private var windowedTimePoints: [TimePlotPoint] {
        guard let last = samples.last else { return [] }
        let cutoff = last.time.addingTimeInterval(-maxWindowSeconds)
        let filtered = samples.filter { $0.time >= cutoff }
        guard !filtered.isEmpty else { return [] }

        if filtered.count == 1, let only = filtered.first {
            let start = only.time.addingTimeInterval(-0.5)
            let mbps = max(0, only.bytesPerSecond) / 1_000_000
            return [
                TimePlotPoint(id: 0, time: start, mbPerSecond: mbps),
                TimePlotPoint(id: 1, time: only.time, mbPerSecond: mbps),
            ]
        }

        return filtered.enumerated().map { idx, sample in
            TimePlotPoint(
                id: idx,
                time: sample.time,
                mbPerSecond: max(0, sample.bytesPerSecond) / 1_000_000
            )
        }
    }

    private var activeMBpsValues: [Double] {
        if usesPercentAxis {
            return samples.map { max(0, $0.bytesPerSecond) / 1_000_000 }
        }
        return windowedTimePoints.map(\.mbPerSecond)
    }

    private var peakMBps: Double {
        activeMBpsValues.max() ?? 0
    }

    private var averageMBps: Double? {
        if let explicit = averageBytesPerSecond, explicit > 0 {
            return explicit / 1_000_000
        }
        let nonZero = activeMBpsValues.filter { $0 > 0 }
        guard !nonZero.isEmpty else { return nil }
        return nonZero.reduce(0, +) / Double(nonZero.count)
    }

    private var yDomainMax: Double {
        let highest = max(peakMBps, averageMBps ?? 0)
        guard highest > 0 else { return 100 }
        let padded = highest * 1.12
        let step: Double
        if padded <= 10 {
            step = 2
        } else if padded <= 50 {
            step = 10
        } else if padded <= 250 {
            step = 25
        } else if padded <= 1000 {
            step = 100
        } else {
            step = 250
        }
        return ceil(padded / step) * step
    }

    private var timeXDomain: ClosedRange<Date>? {
        guard let first = windowedTimePoints.first?.time,
              let last = windowedTimePoints.last?.time else {
            return nil
        }
        let span = max(5.0, min(maxWindowSeconds, last.timeIntervalSince(first)))
        return first...first.addingTimeInterval(span)
    }

    public var body: some View {
        let yMax = yDomainMax

        if usesPercentAxis {
            let pts = percentPoints
            if !pts.isEmpty {
                Chart {
                    ForEach(pts) { pt in
                        AreaMark(
                            x: .value("Progress", pt.fraction),
                            yStart: .value("Baseline", 0),
                            yEnd: .value("Speed (MB/s)", pt.mbPerSecond)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(areaGradient)

                        LineMark(
                            x: .value("Progress", pt.fraction),
                            y: .value("Speed (MB/s)", pt.mbPerSecond)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.accentColor)
                    }

                    if let avg = averageMBps, avg > 0 {
                        RuleMark(y: .value("Avg", avg))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.65))
                    }
                }
                .chartYScale(domain: 0...yMax)
                .chartXScale(domain: 0.0...1.0)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: [0, yMax / 2, yMax]) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.primary.opacity(0.08))
                    }
                }
                .frame(height: chartHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
            }
        } else {
            let pts = windowedTimePoints
            if !pts.isEmpty {
                Chart {
                    ForEach(pts) { pt in
                        AreaMark(
                            x: .value("Time", pt.time),
                            yStart: .value("Baseline", 0),
                            yEnd: .value("Speed (MB/s)", pt.mbPerSecond)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(areaGradient)

                        LineMark(
                            x: .value("Time", pt.time),
                            y: .value("Speed (MB/s)", pt.mbPerSecond)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.accentColor)
                    }

                    if let avg = averageMBps, avg > 0 {
                        RuleMark(y: .value("Avg", avg))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.65))
                    }
                }
                .chartYScale(domain: 0...yMax)
                .chartXScale(domain: timeXDomain ?? Date()...Date().addingTimeInterval(5))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: [0, yMax / 2, yMax]) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.primary.opacity(0.08))
                    }
                }
                .frame(height: chartHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
            }
        }
    }

    private var areaGradient: LinearGradient {
        let topOpacity = colorScheme == .dark ? 0.45 : 0.30
        let bottomOpacity = colorScheme == .dark ? 0.12 : 0.06
        return LinearGradient(
            colors: [
                Color.accentColor.opacity(topOpacity),
                Color.accentColor.opacity(bottomOpacity),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var accessibilitySummary: String {
        guard let avg = averageMBps else {
            return "Transfer speed graph"
        }
        let avgStr = SpeedFormatting.speed(avg * 1_000_000)
        let peakStr = SpeedFormatting.speed(peakMBps * 1_000_000)
        return "Transfer speed graph, average \(avgStr), peak \(peakStr)"
    }
}
