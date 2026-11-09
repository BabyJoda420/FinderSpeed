// App/AppDelegate.swift (owner: zeus)
// Owns the engine and the menu bar item, and wires Engine → Window → UI together.

import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = TransferMonitor()
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.start()
        setUpStatusItem()
        monitor.$transfers
            .receive(on: RunLoop.main)
            .sink { [weak self] transfers in self?.updateStatusItem(transfers) }
            .store(in: &cancellables)
        PanelWiring.install(app: self)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "FinderSpeed")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The menu bar shows the combined live speed while anything is copying. This also covers the
    /// first ~3 s before Finder shows its progress window, and copies too short to get a window at all.
    private func updateStatusItem(_ transfers: [Transfer]) {
        let active = transfers.filter { !$0.isFinished }
        guard !active.isEmpty else { statusItem.button?.title = ""; return }
        if active.allSatisfy(\.isPreparing) { statusItem.button?.title = " Preparing…"; return }
        let total = active.reduce(0) { $0 + $1.bytesPerSecond }
        statusItem.button?.title = " " + Self.formatSpeed(total)
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        SpeedFormatting.speed(bytesPerSecond)   // Thor's formatter: decimal units, matching Finder
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let active = monitor.transfers.filter { !$0.isFinished }
        if active.isEmpty {
            menu.addItem(withTitle: "No Finder copies running", action: nil, keyEquivalent: "")
        } else {
            for t in active {
                let pct = Int((t.fractionCompleted * 100).rounded())
                menu.addItem(withTitle: "\(t.displayName) → \(t.destinationDisplayName): \(Self.formatSpeed(t.bytesPerSecond)) · \(pct)%",
                             action: nil, keyEquivalent: "")
            }
        }
        menu.addItem(.separator())
        if AccessibilityPermission.isTrusted {
            menu.addItem(withTitle: "Accessibility: granted ✓", action: nil, keyEquivalent: "")
        } else {
            let item = menu.addItem(withTitle: "Grant Accessibility access…  (needed to attach to Finder's window)",
                                    action: #selector(requestAccessibility), keyEquivalent: "")
            item.target = self
        }
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        let demo = menu.addItem(withTitle: "Show Demo Panel", action: #selector(showDemo), keyEquivalent: "d")
        demo.target = self
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        menu.addItem(withTitle: "FinderSpeed \(version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit FinderSpeed", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func requestAccessibility() { AccessibilityPermission.prompt() }
    @objc private func showDemo() { PanelWiring.showDemo(app: self) }
    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.toggle() }
}

/// "Launch at Login" via SMAppService (macOS 13+). Only works when running from an .app bundle.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove FinderSpeed.app to /Applications and try again."
            alert.runModal()
        }
    }
}
