// UI/SpeedGraphView.swift (owner: thor)
// Swift Charts throughput graph in Finder's text column (width 311, height 64, no box or border).
// Uses a TIME x-axis that always spans full width from the first sample to the latest sample.
// For transfers with fewer than 3 samples, shows a compact 'measuring' placeholder line instead of a sliver.

import Charts
import SwiftUI

public struct SpeedGraphView: View {
    public let samples: [SpeedSample]
    public var bytesTotal: Int64
    public var averageBytesPerSecond: Double?
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

    private var timePoints: [TimePlotPoint] {
        samples.enumerated().map { idx, sample in
            TimePlotPoint(
                id: idx,
                time: sample.time,
                mbPerSecond: max(0, sample.bytesPerSecond) / 1_000_000
            )
        }
    }

    private var peakMBps: Double {
        samples.map { max(0, $0.bytesPerSecond) / 1_000_000 }.max() ?? 0
    }

    private var averageMBps: Double? {
        if let explicit = averageBytesPerSecond, explicit > 0 {
            return explicit / 1_000_000
        }
        let nonZero = samples.map { max(0, $0.bytesPerSecond) / 1_000_000 }.filter { $0 > 0 }
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
        guard let first = samples.first?.time,
              let last = samples.last?.time else {
            return nil
        }
        return first < last ? first...last : first...first.addingTimeInterval(0.001)
    }

    public var body: some View {
        if samples.count < 3 {
            Text("Measuring…")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Measuring throughput")
        } else {
            let pts = timePoints
            let yMax = yDomainMax
            if let xDomain = timeXDomain {
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
                .chartXScale(domain: xDomain)
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
