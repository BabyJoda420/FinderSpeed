// Throwaway driver for the Window module (apollo). Not part of the package.
// Build: spikes/window/driver/build.sh   Run: spikes/window/driver/window-driver [seconds]
import AppKit
import SwiftUI

setvbuf(stdout, nil, _IOLBF, 0)
let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 40 : 40
let t0 = Date()
func log(_ s: String) { print(String(format: "[%6.0fms] ", Date().timeIntervalSince(t0) * 1000) + s) }

final class DriverState: ObservableObject {
    @Published var expanded = false
    @Published var rows: [FinderProgressWindowObserver.Row] = []
}

struct DriverView: View {
    @ObservedObject var monitor: TransferMonitor
    @ObservedObject var state: DriverState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if monitor.transfers.isEmpty {
                Text("Waiting for transfer…").font(.system(size: 12, weight: .semibold))
            }
            ForEach(monitor.transfers) { t in
                Text(String(format: "%@ → %@: %.0f MB/s", t.displayName, t.destinationDisplayName, t.bytesPerSecond / 1e6))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            Text("Rows: \(state.rows.count)  " + state.rows.map { $0.destinationName ?? "?" }.joined(separator: ", "))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if state.expanded {
                RoundedRectangle(cornerRadius: 4).fill(.blue.opacity(0.3)).frame(height: 80)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    log("AX trusted = \(AccessibilityPermission.isTrusted)")
    let monitor = TransferMonitor()
    monitor.start()
    let state = DriverState()

    let observer = FinderProgressWindowObserver()
    observer.debugLogging = true
    let hints = FinderDestinationHints(monitor: monitor)
    hints.debugLogging = true
    let panel = SpeedPanelController(content: DriverView(monitor: monitor, state: state))
    panel.debugLogging = true

    observer.addHandler { event, info in
        state.rows = info?.rows ?? []
        if event == .rowsChanged { return }   // ~2 Hz, logged by the tick below
        log("event \(event) frame=\(info.map { "\($0.frame)" } ?? "-") id=\(info?.windowID.map(String.init) ?? "-") rows=\(info?.rowCount ?? 0)")
    }
    hints.attach(to: observer)
    panel.attach(to: observer)
    observer.start()

    // Every second: transfers, rows, panel geometry and window-server ordering.
    let tick = Timer(timeInterval: 1.0, repeats: true) { _ in
        MainActor.assumeIsolated {
            for t in monitor.transfers {
                log(String(format: "transfer %@ -> %@  %.0f MB/s  %lld/%lld  samples=%d",
                           t.displayName, t.destinationFolder.path, t.bytesPerSecond / 1e6,
                           t.bytesCompleted, t.bytesTotal, t.samples.count))
            }
            guard let w = observer.window else { return }
            for r in w.rows {
                log("  row \(r.index) dest=\(r.destinationName ?? "nil") -> \(hints.destination(for: r)?.path ?? "unresolved") status=\"\(r.status)\" bytes=\(r.statusBytesCompleted.map(String.init) ?? "nil")")
            }
            let order = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let nums = order.compactMap { $0[kCGWindowNumber as String] as? Int }
            let iPanel = nums.firstIndex(of: panel.windowNumber)
            let iFinder = w.windowID.flatMap { nums.firstIndex(of: Int($0)) }
            let flush = abs(panel.frame.maxY - w.frame.minY) < 0.5 && panel.frame.minX == w.frame.minX && panel.frame.width == w.frame.width
            log("  panel shown=\(panel.isShown) frame=\(panel.frame) flushUnderFinder=\(flush) zIndex panel=\(iPanel.map(String.init) ?? "-") finder=\(iFinder.map(String.init) ?? "-") (front=0)")
        }
    }
    RunLoop.main.add(tick, forMode: .common)

    // Exercise the content-height path: expand the fake graph after 8 s, collapse after 11 s.
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { state.expanded = true; log("expand content") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 11) { state.expanded = false; log("collapse content") }
    // Exercise moving: nudge Finder's window through AX after 6 s and back after 7 s.
    if CommandLine.arguments.contains("--nudge") {
        func move(dx: CGFloat) {
            guard let f = FinderApp.running else { return }
            let appEl = AXUIElementCreateApplication(f.processIdentifier)
            for w in AX.windows(appEl) ?? [] where AX.string(w, kAXIdentifierAttribute) == "Progress" {
                guard var p = AX.frame(w)?.origin else { continue }
                p.x += dx
                AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
                log("nudged Finder window by \(dx)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { move(dx: 60) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { move(dx: -60) }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { log("done"); exit(0) }
    withExtendedLifetime((monitor, observer, hints, panel, tick)) { app.run() }
}
