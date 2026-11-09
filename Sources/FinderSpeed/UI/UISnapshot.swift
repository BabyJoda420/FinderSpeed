// UI/UISnapshot.swift (owner: thor)
// Renders SpeedPanelView(transfers: DemoTransfers.make()) into 2x PNG snapshots across light/dark and collapsed/expanded states.

import AppKit
import SwiftUI

public enum UISnapshot {

    public enum SnapshotError: Error, LocalizedError {
        case renderFailed(String)
        case pngEncodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .renderFailed(let name):
                return "ImageRenderer failed to produce a CGImage for \(name)"
            case .pngEncodingFailed(let name):
                return "Failed to encode PNG data for \(name)"
            }
        }
    }

    /// Renders `SpeedPanelView(transfers: DemoTransfers.make())` at 404pt wide (2x scale) into `directory`
    /// in 4 variants:
    /// - `panel-light-collapsed.png`
    /// - `panel-light-expanded.png`
    /// - `panel-dark-collapsed.png`
    /// - `panel-dark-expanded.png`
    @MainActor
    public static func renderDemo(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        let hadPreviousValue = defaults.object(forKey: "graphExpanded") != nil
        let previousExpanded = defaults.bool(forKey: "graphExpanded")
        defer {
            if hadPreviousValue {
                defaults.set(previousExpanded, forKey: "graphExpanded")
            } else {
                defaults.removeObject(forKey: "graphExpanded")
            }
        }

        let referenceDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let transfers = DemoTransfers.make(now: referenceDate)

        let variants: [(filename: String, scheme: ColorScheme, appearanceName: NSAppearance.Name, expanded: Bool)] = [
            ("panel-light-collapsed.png", .light, .aqua, false),
            ("panel-light-expanded.png", .light, .aqua, true),
            ("panel-dark-collapsed.png", .dark, .darkAqua, false),
            ("panel-dark-expanded.png", .dark, .darkAqua, true),
        ]

        for variant in variants {
            defaults.set(variant.expanded, forKey: "graphExpanded")

            let content = SpeedPanelView(transfers: transfers)
                .frame(width: 404)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, variant.scheme)
                .environment(\.graphExpandedOverride, variant.expanded)

            let appearance = NSAppearance(named: variant.appearanceName)
            var renderedCGImage: CGImage?
            let renderBlock = {
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2.0
                renderedCGImage = renderer.cgImage
            }

            if let appearance {
                appearance.performAsCurrentDrawingAppearance(renderBlock)
            } else {
                renderBlock()
            }

            guard let cgImage = renderedCGImage else {
                throw SnapshotError.renderFailed(variant.filename)
            }

            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            bitmapRep.size = NSSize(width: CGFloat(cgImage.width) / 2.0, height: CGFloat(cgImage.height) / 2.0)
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                throw SnapshotError.pngEncodingFailed(variant.filename)
            }

            let fileURL = directory.appendingPathComponent(variant.filename)
            try pngData.write(to: fileURL, options: .atomic)
        }
    }
}
