// App/PanelWiring.swift (owner: zeus)
// Connects Engine (TransferMonitor) → Window (observer, hints, attached panel) → UI (SpeedPanelView).

import AppKit
import SwiftUI

/// The top-to-bottom order of destinations in Finder's progress window, so our rows can follow it.
@MainActor
final class FinderRowOrder: ObservableObject {
    /// Destination keys (standardized folder path, else the quoted folder name) in Finder's row order.
    @Published var keys: [String] = []

    /// Sorts transfers to match Finder's rows. Transfers Finder doesn't show (yet) keep their
    /// engine order and go after the matched ones.
    func sorted(_ transfers: [Transfer]) -> [Transfer] {
        guard !keys.isEmpty else { return transfers }
        func rank(_ t: Transfer) -> Int {
            let path = t.destinationFolder.standardizedFileURL.path
            return keys.firstIndex(of: path) ?? keys.firstIndex(of: t.destinationDisplayName) ?? Int.max
        }
        return transfers.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}

/// Re-renders Thor's SpeedPanelView whenever the engine publishes new transfers or Finder reorders rows.
struct LiveSpeedPanel: View {
    @ObservedObject var monitor: TransferMonitor
    @ObservedObject var order: FinderRowOrder
    var body: some View {
        SpeedPanelView(transfers: order.sorted(monitor.transfers))
    }
}

@MainActor
enum PanelWiring {
    private static var observer: FinderProgressWindowObserver?
    private static var hints: FinderDestinationHints?
    private static var panel: SpeedPanelController?
    private static var demoWindow: NSWindow?
    private static let rowOrder = FinderRowOrder()

    static func install(app: AppDelegate) {
        let monitor = app.monitor
        let observer = FinderProgressWindowObserver()
        let hints = FinderDestinationHints(monitor: monitor)
        hints.attach(to: observer)

        let panel = SpeedPanelController(content: LiveSpeedPanel(monitor: monitor, order: rowOrder))
        panel.attach(to: observer)

        // Fallback byte source: Finder's own "X of Y" text. Rows that go to the same destination
        // folder are summed, because the engine keeps one transfer per destination folder.
        observer.addHandler { [weak hints, weak monitor] event, info in
            guard event == .rowsChanged || event == .appeared,
                  let info, let hints, let monitor else { return }
            var perDestination: [String: (url: URL?, name: String?, bytes: Int64, total: Int64?)] = [:]
            var orderKeys: [String] = []
            for row in info.rows {
                let rowKey = hints.destination(for: row)?.standardizedFileURL.path ?? row.destinationName
                if let rowKey, !orderKeys.contains(rowKey) { orderKeys.append(rowKey) }
                guard let bytes = row.statusBytesCompleted else { continue }
                let url = hints.destination(for: row)
                let key = url?.standardizedFileURL.path ?? row.destinationName ?? "?"
                var entry = perDestination[key] ?? (url, row.destinationName, 0, 0)
                entry.bytes += bytes
                // A total is only meaningful if every row for this folder reports one.
                entry.total = row.statusBytesTotal.flatMap { t in entry.total.map { $0 + t } }
                perDestination[key] = entry
            }
            if rowOrder.keys != orderKeys { rowOrder.keys = orderKeys }
            let now = Date()
            for entry in perDestination.values {
                monitor.noteWindowRow(destination: entry.url, destinationName: entry.name,
                                      bytesCompleted: entry.bytes, bytesTotal: entry.total, timestamp: now)
            }
        }

        if !AccessibilityPermission.isTrusted { AccessibilityPermission.prompt() }
        observer.start()   // waits for the Accessibility grant by itself

        self.observer = observer
        self.hints = hints
        self.panel = panel
    }

    /// A free-standing window with fake data, so the UI can be seen without running a copy.
    static func showDemo(app: AppDelegate) {
        if let w = demoWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let host = NSHostingView(rootView: SpeedPanelView(transfers: DemoTransfers.make()))
        let effect = NSVisualEffectView()
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: 404),
        ])
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 404, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "FinderSpeed: Demo"
        w.isReleasedWhenClosed = false
        w.contentView = effect
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        demoWindow = w
    }
}
