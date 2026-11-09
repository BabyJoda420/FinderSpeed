// Window/SpeedPanelController.swift (owner: apollo)
//
// Attaches the speed panel to Finder's copy-progress window so that both read as ONE window
// (BRIEF.md, Phase 3):
//  * Chrome window (ignores ALL mouse events, ordered directly above Finder's window): our own
//    outline ring and shadow, computed so that Finder's shadow + ours = the shadow of a single
//    window with the combined shape (WindowChrome.swift), plus the "cap band": the
//    `WindowChromeRenderer.bandHeight` rows ABOVE Finder's bottom edge, where it paints only Finder's
//    bottom-corner curves (turning them square) and a 4 px strip over Finder's bottom rim. The rest of
//    the band is transparent, so Finder's text stays visible; clicks anywhere in this window go to
//    whatever is below (a masked material in a click-taking window would swallow them, measured).
//  * Body window (takes clicks, above the chrome window): starts exactly at Finder's bottom edge.
//    Finder's width, square top, Finder-shaped bottom corners. Both windows have hasShadow = false.
//  * Fill: Finder's exact on-screen background colour when Screen Recording is already granted
//    (FinderBackgroundSampler); otherwise the closest material (.windowBackground, state following
//    Finder's window). The material tint depends on the window's own position, so the fallback
//    is a few units off (see spikes/window/PHASE3.md).
//  * Content: the SwiftUI view's origin is Finder's bottom-left edge, width = Finder's width.
//    Its height is the content's fitting height; the panel never shows below
//    `minimumContentHeight` (fixes the 1 px panel at startup).
//  * Level .normal, ordered directly above Finder's window: other apps' windows still cover it.

import AppKit
import SwiftUI

@MainActor
public final class SpeedPanelController {

    // MARK: Configuration

    public var fadeDuration: TimeInterval = 0.2
    /// Duration of the height animation when the content's fitting height changes.
    public var resizeDuration: TimeInterval = 0.25
    /// Content shorter than this is treated as empty: the panel stays hidden.
    public var minimumContentHeight: CGFloat = 8
    public var debugLogging = false

    // MARK: State

    /// True while the panel is (being) shown.
    public private(set) var isShown = false
    /// The body window's number. The chrome (shadow + band) window is ordered just below it.
    public var windowNumber: Int { body.windowNumber }
    public var shadowWindowNumber: Int { shadow.windowNumber }
    /// The body window's frame (AppKit coordinates) = the content rect: x/width = Finder's,
    /// top = Finder's bottom edge.
    public var frame: NSRect { body.frame }
    public var contentFrame: NSRect { body.frame }
    /// True when the fill uses Finder's sampled colour (exact), false for the material fallback.
    public private(set) var usesSampledBackground = false

    // MARK: Init

    public convenience init(rootView: AnyView) {
        self.init(content: rootView)
    }

    public init<Content: View>(content: Content) {
        body = ChromePanel(contentRect: NSRect(x: 0, y: 0, width: 404, height: 40))
        shadow = ChromePanel(contentRect: NSRect(x: 0, y: 0, width: 404, height: 40))
        hostingView = PanelHostingView(rootView: AnyView(content))
        debugLogging = ProcessInfo.processInfo.environment["FINDERSPEED_DEBUG_WINDOW"] != nil
        configureWindows()
        hostingView.onIntrinsicSizeChange = { [weak self] in self?.scheduleRelayout() }
    }

    /// Replaces the SwiftUI content.
    public func setContent<Content: View>(_ content: Content) {
        hostingView.rootView = AnyView(content)
        scheduleRelayout()
    }

    /// Follows `observer`'s progress window.
    public func attach(to observer: FinderProgressWindowObserver) {
        detach()
        self.observer = observer
        token = observer.addHandler { [weak self] event, info in self?.handle(event, info) }
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        })
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appearanceChanged() } }
        }
        if observer.window != nil { handle(.appeared, observer.window) }
    }

    public func detach() {
        if let t = token { observer?.removeHandler(t) }
        token = nil
        observer = nil
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()
        appearanceObservation = nil
        hide()
    }

    // MARK: Private: views

    private let body: ChromePanel
    private let shadow: ChromePanel
    private let hostingView: PanelHostingView
    private let rootView = PassThroughView()
    private let fillEffect = NSVisualEffectView()
    private let fillSolid = PassThroughView()
    private let fillSolidMask = CALayer()
    private let overlayView = PassThroughView()
    private let shadowRoot = PassThroughView()
    private let shadowView = PassThroughView()
    private let bandEffect = NSVisualEffectView()
    private let bandSolid = PassThroughView()
    private let bandSolidMask = CALayer()
    private let bandOverlay = PassThroughView()
    private var widthConstraint: NSLayoutConstraint?

    private weak var observer: FinderProgressWindowObserver?
    private var token: FinderProgressWindowObserver.HandlerToken?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    private var target: FinderProgressWindowObserver.WindowInfo?
    private var relayoutPending = false
    private var fadeGeneration = 0
    private var displayedHeight: CGFloat = 0     // body height currently laid out
    private var heightAnimation: Timer?
    private var renderedKey: RenderKey?
    private var renderedPads = (x: 0, below: 0)

    private let sampler = FinderBackgroundSampler()
    private var sampledColor: CGColor?
    private var sampleDebounce: DispatchWorkItem?
    private var waitingForSample = false

    private struct RenderKey: Equatable { let width: Int; let height: Int; let dark: Bool; let active: Bool }

    private func log(_ s: @autoclosure () -> String) {
        if debugLogging { print("[panel] \(s())"); fflush(stdout) }
    }

    private func configureWindows() {
        for w in [body, shadow] {
            w.isFloatingPanel = false
            w.level = .normal
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            w.worksWhenModal = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isMovable = false
            w.isMovableByWindowBackground = false
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            w.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
            w.alphaValue = 0
        }
        shadow.ignoresMouseEvents = true

        // Chrome window: the computed shadow image, then the band (fill + rim) over Finder's bottom.
        shadowRoot.wantsLayer = true
        shadow.contentView = shadowRoot
        shadowView.wantsLayer = true
        shadowView.layer?.contentsGravity = .resize
        shadowView.layer?.magnificationFilter = .linear
        shadowRoot.addSubview(shadowView)
        bandEffect.material = .windowBackground
        bandEffect.blendingMode = .behindWindow
        bandEffect.state = .inactive
        shadowRoot.addSubview(bandEffect)
        bandSolid.wantsLayer = true
        bandSolidMask.contentsGravity = .resize
        bandSolid.layer?.mask = bandSolidMask
        bandSolid.isHidden = true
        shadowRoot.addSubview(bandSolid)
        bandOverlay.wantsLayer = true
        bandOverlay.layer?.contentsGravity = .resize
        shadowRoot.addSubview(bandOverlay)

        // Body window: fill (material or solid), content, edge overlay. No band: starts at Finder's bottom.
        rootView.wantsLayer = true
        body.contentView = rootView

        fillEffect.material = .windowBackground
        fillEffect.blendingMode = .behindWindow
        fillEffect.state = .inactive
        fillEffect.autoresizingMask = [.width, .height]
        rootView.addSubview(fillEffect)

        fillSolid.wantsLayer = true
        fillSolid.autoresizingMask = [.width, .height]
        fillSolidMask.contentsGravity = .resize
        fillSolid.layer?.mask = fillSolidMask
        fillSolid.isHidden = true
        rootView.addSubview(fillSolid)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(hostingView)
        let wc = hostingView.widthAnchor.constraint(equalToConstant: 404)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: rootView.topAnchor),
            wc,
        ])
        widthConstraint = wc

        overlayView.wantsLayer = true
        overlayView.layer?.contentsGravity = .resize
        overlayView.autoresizingMask = [.width, .height]
        rootView.addSubview(overlayView)   // above the content: the rim is part of the window edge
    }

    // MARK: Events

    private func handle(_ event: FinderProgressWindowObserver.Event, _ info: FinderProgressWindowObserver.WindowInfo?) {
        let old = target
        target = info
        switch event {
        case .disappeared:
            hide()
            sampledColor = nil
        case .appeared:
            requestSample(after: 0)
            sync()
        case .activationChanged:
            requestSample(after: 0.35)   // after Finder's own active/inactive transition
            sync()
        case .moved:
            requestSample(after: 0.3)    // the tint follows the window's position
            sync()
        case .resized:
            requestSample(after: 0.3)    // the tint follows the window's frame, height included
            sync()
        case .minimizedChanged, .orderingMayHaveChanged:
            if old?.frame.size != info?.frame.size { requestSample(after: 0.3) }
            sync()
        case .rowsChanged:
            break   // the content (App/UI) reacts to rows; the frame only changes on .resized
        }
    }

    private func appearanceChanged() {
        renderedKey = nil
        requestSample(after: 0.3)
        sync()
    }

    // MARK: Layout

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Brings the panel in line with `target`: visibility, frame, ordering.
    private func sync() {
        guard let t = target, let wid = t.windowID else { hide(); return }
        guard !t.isMinimized, !(FinderApp.running?.isHidden ?? false), Self.isOnScreen(wid) else {
            hide(); return
        }
        let h = fittingHeight(width: t.frame.width)
        guard h >= minimumContentHeight else { hide(); return }
        // While the height animates, keep its current height (the frame still follows Finder).
        layout(height: heightAnimation != nil ? displayedHeight : h)
        ensureOrdered(above: wid)
        if waitingForSample { return }   // shown once the colour is known (or the wait timed out)
        show()
    }

    private func fittingHeight(width: CGFloat) -> CGFloat {
        widthConstraint?.constant = width
        hostingView.layoutSubtreeIfNeeded()
        return ceil(hostingView.fittingSize.height)
    }

    /// Lays out both windows for a body of height `height` under Finder's current frame.
    private func layout(height: CGFloat) {
        guard let t = target else { return }
        let f = t.frame
        let W = Int(f.width.rounded()), H = max(1, Int(height.rounded()))
        let band = WindowChromeRenderer.bandHeight
        let key = RenderKey(width: W, height: H, dark: isDark, active: t.isActive)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if key != renderedKey {
            let profile = WindowChromeProfile.profile(dark: key.dark, active: key.active)
            if let img = WindowChromeRenderer.render(profile: profile, width: W, height: H),
               let bandMask = img.mask.cropping(to: CGRect(x: 0, y: 0, width: W, height: band)),
               let bodyMask = img.mask.cropping(to: CGRect(x: 0, y: band, width: W, height: H)),
               let bandOvl = img.overlay.cropping(to: CGRect(x: 0, y: 0, width: W, height: band)),
               let bodyOvl = img.overlay.cropping(to: CGRect(x: 0, y: band, width: W, height: H)) {
                shadowView.layer?.contents = img.shadow
                overlayView.layer?.contents = bodyOvl
                fillEffect.maskImage = NSImage(cgImage: bodyMask, size: NSSize(width: W, height: H))
                fillSolidMask.contents = bodyMask
                bandOverlay.layer?.contents = bandOvl
                bandEffect.maskImage = NSImage(cgImage: bandMask, size: NSSize(width: W, height: band))
                bandSolidMask.contents = bandMask
                renderedPads = (img.padX, img.padBelow)
                renderedKey = key
            }
            fillEffect.state = key.active ? .active : .inactive
            bandEffect.state = fillEffect.state
        }
        let x = f.minX.rounded(), bottom = f.minY.rounded()
        let bodyFrame = NSRect(x: x, y: bottom - CGFloat(H), width: CGFloat(W), height: CGFloat(H))
        let shadowFrame = NSRect(x: x - CGFloat(renderedPads.x), y: bottom - CGFloat(H + renderedPads.below),
                                 width: CGFloat(W + 2 * renderedPads.x), height: CGFloat(band + H + renderedPads.below))
        if shadow.frame != shadowFrame { shadow.setFrame(shadowFrame, display: true) }
        if body.frame != bodyFrame { body.setFrame(bodyFrame, display: true) }
        // Explicit frames: these subviews start at .zero, which autoresizing would keep at zero.
        let bounds = NSRect(origin: .zero, size: bodyFrame.size)
        for v in [fillEffect, fillSolid, overlayView] as [NSView] where v.frame != bounds { v.frame = bounds }
        fillSolidMask.frame = bounds
        shadowView.frame = NSRect(origin: .zero, size: shadowFrame.size)
        let bandFrame = NSRect(x: CGFloat(renderedPads.x), y: shadowFrame.height - CGFloat(band),
                               width: CGFloat(W), height: CGFloat(band))
        for v in [bandEffect, bandSolid, bandOverlay] as [NSView] where v.frame != bandFrame { v.frame = bandFrame }
        bandSolidMask.frame = NSRect(origin: .zero, size: bandFrame.size)
        CATransaction.commit()
        displayedHeight = CGFloat(H)
        log("layout body \(bodyFrame) shadow \(shadowFrame) active=\(key.active) dark=\(key.dark)")
    }

    private func scheduleRelayout() {
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.relayoutPending = false
                self.contentSizeChanged()
            }
        }
    }

    /// The SwiftUI content changed its fitting height (e.g. the graph expands): animate to it.
    private func contentSizeChanged() {
        guard let t = target else { return }
        let h = fittingHeight(width: t.frame.width)
        guard h >= minimumContentHeight else { hide(); return }
        guard isShown, resizeDuration > 0, abs(h - displayedHeight) >= 1 else { sync(); return }
        heightAnimation?.invalidate()
        let from = displayedHeight, start = Date(), duration = resizeDuration
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let p = min(1, Date().timeIntervalSince(start) / duration)
                let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2     // easeInOut
                self.layout(height: from + (h - from) * CGFloat(e))
                if p >= 1 { timer.invalidate(); self.heightAnimation = nil; self.sync() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heightAnimation = timer
    }

    /// Orders the shadow window directly above Finder's window and the body directly above that.
    private func ensureOrdered(above wid: CGWindowID) {
        let b = body.windowNumber, s = shadow.windowNumber
        if body.isVisible, shadow.isVisible, b > 0, s > 0,
           let above = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, wid) as? [[String: Any]] {
            let nums = above.compactMap { $0[kCGWindowNumber as String] as? Int }
            if nums.count >= 2, nums[nums.count - 1] == s, nums[nums.count - 2] == b { return }
        }
        shadow.order(.above, relativeTo: Int(wid))
        body.order(.above, relativeTo: shadow.windowNumber)
        log("ordered above Finder window \(wid)")
    }

    private static func isOnScreen(_ wid: CGWindowID) -> Bool {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]])?.first else { return false }
        return info[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    // MARK: Background colour

    private func requestSample(after delay: TimeInterval) {
        sampleDebounce?.cancel()
        guard FinderBackgroundSampler.isAvailable else { applyFill(nil); return }
        if !isShown && delay == 0 {
            // Appearing: wait briefly for the exact colour so the panel doesn't fade in with the
            // wrong one, but never longer than 0.4 s.
            waitingForSample = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.waitingForSample else { return }
                    self.waitingForSample = false
                    self.sync()
                }
            }
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.sampleNow() }
        }
        sampleDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func sampleNow() {
        guard let wid = target?.windowID else { return }
        sampler.debugLogging = debugLogging
        let ours = [body.windowNumber, shadow.windowNumber].filter { $0 > 0 }.map { CGWindowID($0) }
        sampler.sample(finderWindow: wid, excluding: ours) { [weak self] color in
            guard let self else { return }
            self.applyFill(color)
            if self.waitingForSample {
                self.waitingForSample = false
                self.sync()
            }
        }
    }

    private func applyFill(_ color: CGColor?) {
        sampledColor = color
        usesSampledBackground = color != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (solid, effect) in [(fillSolid, fillEffect), (bandSolid, bandEffect)] {
            if let color {
                solid.layer?.backgroundColor = color
                solid.isHidden = false
                effect.isHidden = true
            } else {
                solid.isHidden = true
                effect.isHidden = false
            }
        }
        CATransaction.commit()
    }

    // MARK: Show / hide

    private func show() {
        guard !isShown else { return }
        isShown = true
        fadeGeneration += 1
        log("show")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeDuration
            body.animator().alphaValue = 1
            shadow.animator().alphaValue = 1
        }
    }

    private func hide() {
        heightAnimation?.invalidate(); heightAnimation = nil
        waitingForSample = false
        guard isShown else { return }
        isShown = false
        fadeGeneration += 1
        let gen = fadeGeneration
        log("hide")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            body.animator().alphaValue = 0
            shadow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == gen, !self.isShown else { return }
                self.body.orderOut(nil)
                self.shadow.orderOut(nil)
            }
        })
    }
}

/// Never key or main: the panel must not take focus from Finder or anything else.
private final class ChromePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A view that never takes mouse events itself (they go to the views below or, where the window is
/// transparent, to the window below).
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Reports SwiftUI size changes (e.g. the graph expanding) and accepts the first click, so a
/// toggle button works without activating this app first.
private final class PanelHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
