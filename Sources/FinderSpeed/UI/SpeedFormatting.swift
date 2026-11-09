// UI/SpeedFormatting.swift (owner: thor)
// Decimal (base-1000) byte, throughput, percentage, and ETA formatting matching macOS Finder.

import Foundation

public enum SpeedFormatting {

    private static let kb: Double = 1_000
    private static let mb: Double = 1_000_000
    private static let gb: Double = 1_000_000_000
    private static let tb: Double = 1_000_000_000_000

    /// Formats a throughput in bytes/second using Finder-style decimal units (e.g. "742 MB/s", "77.1 MB/s").
    public static func speed(_ bytesPerSecond: Double) -> String {
        let clamped = max(0, bytesPerSecond)
        guard clamped.isFinite else { return "0 KB/s" }

        if clamped < kb {
            if clamped < 1 {
                return "0 KB/s"
            }
            return String(format: "%.0f B/s", clamped)
        } else if clamped < mb {
            let v = clamped / kb
            return v >= 100 ? String(format: "%.0f KB/s", v) : String(format: "%.1f KB/s", v)
        } else if clamped < gb {
            let v = clamped / mb
            if v >= 100 {
                return String(format: "%.0f MB/s", v)
            } else if v >= 10 {
                return String(format: "%.1f MB/s", v)
            } else {
                return String(format: "%.2f MB/s", v)
            }
        } else {
            let v = clamped / gb
            return v >= 10 ? String(format: "%.1f GB/s", v) : String(format: "%.2f GB/s", v)
        }
    }

    /// Formats a byte count using Finder-style decimal units (e.g. "3.10 GB", "512 MB").
    public static func byteCount(_ bytes: Int64) -> String {
        let clamped = Double(max(0, bytes))
        if clamped < kb {
            return String(format: "%.0f B", clamped)
        } else if clamped < mb {
            let v = clamped / kb
            return v >= 100 ? String(format: "%.0f KB", v) : String(format: "%.1f KB", v)
        } else if clamped < gb {
            let v = clamped / mb
            if v >= 100 {
                return String(format: "%.0f MB", v)
            } else if v >= 10 {
                return String(format: "%.1f MB", v)
            } else {
                return String(format: "%.2f MB", v)
            }
        } else if clamped < tb {
            let v = clamped / gb
            if v >= 100 {
                return String(format: "%.0f GB", v)
            } else if v >= 10 {
                return String(format: "%.1f GB", v)
            } else {
                return String(format: "%.2f GB", v)
            }
        } else {
            let v = clamped / tb
            return String(format: "%.2f TB", v)
        }
    }

    /// Formats remaining time from remaining bytes and current speed (e.g. "~12 s left").
    public static func eta(remainingBytes: Int64, bytesPerSecond: Double) -> String? {
        guard remainingBytes > 0, bytesPerSecond > 1024, bytesPerSecond.isFinite else {
            return nil
        }
        let rawSeconds = Double(remainingBytes) / bytesPerSecond
        guard rawSeconds.isFinite, rawSeconds < 86_400 * 7 else { return nil }

        let seconds = max(1, Int(rawSeconds.rounded()))
        if seconds < 60 {
            return "~\(seconds) s left"
        } else if seconds < 3600 {
            let mins = seconds / 60
            let secs = seconds % 60
            if mins < 10 && secs > 0 {
                return "~\(mins) min \(secs) s left"
            }
            return "~\(mins) min left"
        } else {
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            if mins > 0 {
                return "~\(hours) hr \(mins) min left"
            }
            return "~\(hours) hr left"
        }
    }

    /// Formats a progress summary line (retained for callers/tests).
    public static func progressSummary(
        bytesCompleted: Int64,
        bytesTotal: Int64,
        bytesPerSecond: Double
    ) -> String {
        let doneStr = byteCount(bytesCompleted)
        guard bytesTotal > 0 else {
            return "\(doneStr) copied"
        }
        let totalStr = byteCount(bytesTotal)
        let fraction = min(1.0, max(0.0, Double(bytesCompleted) / Double(bytesTotal)))
        let pct = Int((fraction * 100).rounded())
        var parts = ["\(doneStr) of \(totalStr)", "\(pct)%"]
        let remaining = max(0, bytesTotal - bytesCompleted)
        if let etaStr = eta(remainingBytes: remaining, bytesPerSecond: bytesPerSecond) {
            parts.append(etaStr)
        }
        return parts.joined(separator: " · ")
    }

    /// Line 1 (13pt regular, monospaced digits), e.g. "Speed: 742 MB/s".
    public static func primaryHeadline(for transfer: Transfer) -> String {
        if transfer.isFinished {
            if transfer.wasCancelled {
                return "Speed: —"
            }
            if let avg = effectiveAverageSpeed(for: transfer), avg > 0 {
                return "Speed: \(speed(avg))"
            }
            return "Speed: —"
        }
        if transfer.isPreparing {
            return "Preparing…"
        }
        if transfer.isMeasuring {
            return "Measuring…"
        }
        return "Speed: \(speed(transfer.bytesPerSecond))"
    }

    /// Line 2 (11pt secondary, monospaced digits), e.g. "Average 679 MB/s · Peak 792 MB/s".
    /// Appends " → <destination>" only when `showDestination` is true (more than one transfer visible).
    public static func secondaryLine(for transfer: Transfer, showDestination: Bool = false) -> String {
        if transfer.isPreparing || transfer.isMeasuring {
            return showDestination ? "→ \(transfer.destinationDisplayName)" : ""
        }

        let base: String
        if transfer.isFinished {
            if transfer.wasCancelled {
                base = "Cancelled"
            } else if let avg = effectiveAverageSpeed(for: transfer), avg > 0 {
                base = "Finished · average \(speed(avg))"
            } else {
                base = "Finished"
            }
        } else {
            let avg = effectiveAverageSpeed(for: transfer) ?? transfer.bytesPerSecond
            let peak = max(peakSpeed(for: transfer) ?? 0, transfer.bytesPerSecond, avg)
            base = "Average \(speed(avg)) · Peak \(speed(peak))"
        }

        if showDestination {
            return "\(base) → \(transfer.destinationDisplayName)"
        }
        return base
    }

    /// Computes the effective average speed (in bytes/sec) from `transfer.averageBytesPerSecond` or `transfer.samples`.
    public static func effectiveAverageSpeed(for transfer: Transfer) -> Double? {
        if let avg = transfer.averageBytesPerSecond, avg > 0 {
            return avg
        }
        let nonZero = transfer.samples.map(\.bytesPerSecond).filter { $0 > 0 }
        guard !nonZero.isEmpty else { return nil }
        return nonZero.reduce(0, +) / Double(nonZero.count)
    }

    /// Computes the peak speed (in bytes/sec) across `transfer.samples`.
    public static func peakSpeed(for transfer: Transfer) -> Double? {
        guard let maxSample = transfer.samples.map(\.bytesPerSecond).max(), maxSample > 0 else {
            return nil
        }
        return maxSample
    }
}
