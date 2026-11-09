// UI/SpeedPanelView.swift (owner: thor)
// Root SwiftUI view hosted inside SpeedPanelController.
// No top Divider and no own background; columns and vertical rhythm match Finder's progress window.

import SwiftUI

public struct SpeedPanelView: View {
    public let transfers: [Transfer]

    public init(transfers: [Transfer]) {
        self.transfers = transfers
    }

    public var body: some View {
        let multi = transfers.count > 1
        let transferIDs = transfers.map(\.id)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(transfers, id: \.id) { transfer in
                TransferSpeedRow(
                    transfer: transfer,
                    showDestination: multi
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: transferIDs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
