// UI/TransferSpeedRow.swift (owner: thor)
// One row in the attached speed panel, aligned to Finder's exact columns:
// - Icon column: x 17..<51 (width 34)
// - Text + graph column: x 61..<372 (width 311)
// - Control column: chevron centred at x 385.5 (x 372..<399, width 27)

import SwiftUI

private struct GraphExpandedOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var graphExpandedOverride: Bool? {
        get { self[GraphExpandedOverrideKey.self] }
        set { self[GraphExpandedOverrideKey.self] = newValue }
    }
}

public struct TransferSpeedRow: View {
    public let transfer: Transfer
    public var showDestination: Bool

    @AppStorage("graphExpanded") private var graphExpanded: Bool = false
    @Environment(\.graphExpandedOverride) private var graphExpandedOverride

    private var hasSamples: Bool {
        !transfer.samples.isEmpty
    }

    private var isExpanded: Bool {
        graphExpandedOverride ?? graphExpanded
    }

    public init(transfer: Transfer, showDestination: Bool = false) {
        self.transfer = transfer
        self.showDestination = showDestination
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left margin: x 0..<17
            Spacer()
                .frame(width: 17)

            // Icon column: x 17..<51 (width 34)
            Image(systemName: "gauge.with.dots.needle.67percent")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 30, alignment: .center)

            // Gap: x 51..<61 (width 10)
            Spacer()
                .frame(width: 10)

            // Text & Graph column: x 61..<372 (width 311)
            let line2 = SpeedFormatting.secondaryLine(for: transfer, showDestination: showDestination)
            VStack(alignment: .leading, spacing: 0) {
                Text(SpeedFormatting.primaryHeadline(for: transfer))
                    .font(.system(size: 13, weight: .regular).monospacedDigit())
                    .foregroundStyle(headlineColor)
                    .lineLimit(1)
                    .frame(height: 15, alignment: .leading)

                if !line2.isEmpty {
                    Spacer()
                        .frame(height: 2)

                    Text(line2)
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 13, alignment: .leading)
                }

                if isExpanded && hasSamples {
                    SpeedGraphView(transfer: transfer)
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(width: 311, alignment: .leading)

            // Control column: x 372..<399 (width 27 -> centre at x = 372 + 13.5 = 385.5)
            if hasSamples {
                disclosureButton
                    .frame(width: 27, height: 30, alignment: .center)
            } else {
                Spacer()
                    .frame(width: 27, height: 30)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: hasSamples)
    }

    private var headlineColor: Color {
        if transfer.isFinished && transfer.wasCancelled {
            return .secondary
        }
        return .primary
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                graphExpanded.toggle()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide speed graph" : "Show speed graph")
        .accessibilityLabel(isExpanded ? "Collapse speed graph" : "Expand speed graph")
    }
}
