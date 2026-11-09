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
        WindowDiagnostics.logEnvironment(reason: "panel attach")
        if WindowDiagnostics.enabled {
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.target != nil { self.logState("tick") } }
            }
            RunLoop.main.add(t, forMode: .common)
            diagTimer = t
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
    /// Body fill (masked to the body shape: square top, Finder-shaped bottom corners).
    private let bodyFill = FillPatch()
    private let overlayView = PassThroughView()
    private let shadowRoot = PassThroughView()
    private let shadowView = PassThroughView()
    /// Band fill, in three separate patches (BUG-001 (d)): Finder's two bottom-corner curves and the
    /// 4 pt strip over its bottom rim. Even if a mask failed to apply, the band can never be painted
    /// across Finder's full width above the strip.
    private let bandLeft = FillPatch()
    private let bandRight = FillPatch()
    private let bandStrip = FillPatch()
    private let bandOverlay = PassThroughView()
    private var fillPatches: [FillPatch] { [bodyFill, bandLeft, bandRight, bandStrip] }
    private var widthConstraint: NSLayoutConstraint?

    private weak var observer: FinderProgressWindowObserver?
    private var token: FinderProgressWindowObserver.HandlerToken?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var diagTimer: Timer?

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

    private struct RenderKey: Equatable { let width: Int; let height: Int; let dark: Bool; let active: Bool; let scale: Int }

    private func log(_ s: @autoclosure () -> String) {
        if WindowDiagnostics.enabled { WindowDiagnostics.log("panel", s()) }
        else if debugLogging { print("[panel] \(s())"); fflush(stdout) }
    }

    /// Diagnostic snapshot (BUG-001): window alphas, frames, scale, fill mode.
    private func logState(_ reason: String) {
        guard WindowDiagnostics.enabled else { return }
        log("\(reason): shown=\(isShown) opacity=\(String(format: "%.2f/%.2f", Double(rootView.layer?.opacity ?? -1), Double(shadowRoot.layer?.opacity ?? -1))) presented=\(String(format: "%.2f/%.2f", Double(rootView.layer?.presentation()?.opacity ?? -1), Double(shadowRoot.layer?.presentation()?.opacity ?? -1))) winAlpha=\(String(format: "%.2f/%.2f", body.alphaValue, shadow.alphaValue)) "
            + "body=\(body.frame) chrome=\(shadow.frame) visible=\(body.isVisible)/\(shadow.isVisible) "
            + "scale=\(body.backingScaleFactor) screen=\(body.screen?.localizedName ?? "nil") "
            + "fill=\(usesSampledBackground ? "sampled" : "material") "
            + "key=\(renderedKey.map { "\($0.width)x\($0.height)@\($0.scale)x dark=\($0.dark) active=\($0.active)" } ?? "nil")")
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
            // BUG-001 (c): the window alpha is never animated (an AppKit window-alpha animation is
            // driven by the main thread and froze mid-fade when it stalled). Fades use the root
            // layers' opacity instead, whose final value is set immediately.
            w.alphaValue = 1
        }
        shadow.ignoresMouseEvents = true
        for w in [body, shadow] {
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChanged("backing properties") }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChanged("screen") }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged("screen parameters") }
        }

        // Chrome window: the computed shadow image, then the band (fill + rim) over Finder's bottom.
        shadowRoot.wantsLayer = true
        shadow.contentView = shadowRoot
        shadowView.wantsLayer = true
        shadowView.layer?.contentsGravity = .resize
        shadowView.layer?.magnificationFilter = .linear
        shadowRoot.addSubview(shadowView)
        for p in [bandLeft, bandRight, bandStrip] { shadowRoot.addSubview(p) }
        bandOverlay.wantsLayer = true
        bandOverlay.layer?.contentsGravity = .resize
        shadowRoot.addSubview(bandOverlay)

        // Body window: fill (material or solid), content, edge overlay. No band: starts at Finder's bottom.
        rootView.wantsLayer = true
        body.contentView = rootView
        rootView.addSubview(bodyFill)

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
        rootView.alphaValue = 0
        shadowRoot.alphaValue = 0
    }

    /// The panel moved to another screen or the backing scale changed: re-render at the new scale.
    private func screenChanged(_ what: String) {
        log("\(what) changed: scale \(body.backingScaleFactor), screen \(body.screen?.localizedName ?? "nil")")
        renderedKey = nil
        if target != nil { sync() }
    }

    /// The backing scale of the screen Finder's window is on (our windows may not be on screen yet).
    private func backingScale(for frame: NSRect) -> Int {
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(frame).width * a.frame.intersection(frame).height
                < b.frame.intersection(frame).width * b.frame.intersection(frame).height
        }
        return max(1, Int((screen?.backingScaleFactor ?? body.backingScaleFactor).rounded()))
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
        let scale = backingScale(for: f)
        let key = RenderKey(width: W, height: H, dark: isDark, active: t.isActive, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cw = WindowChromeRenderer.cornerPatchWidth, sh = WindowChromeRenderer.stripHeight
        if key != renderedKey {
            let profile = WindowChromeProfile.profile(dark: key.dark, active: key.active)
            if let img = WindowChromeRenderer.render(profile: profile, width: W, height: H, scale: scale) {
                // Crops in pixels; images are `scale` pixels per point.
                func crop(_ i: CGImage, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGImage? {
                    i.cropping(to: CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale))
                }
                let cornerRows = band - sh
                if let bodyMask = crop(img.mask, 0, band, W, H),
                   let leftMask = crop(img.mask, 0, 0, cw, cornerRows),
                   let rightMask = crop(img.mask, W - cw, 0, cw, cornerRows),
                   let bandOvl = crop(img.overlay, 0, 0, W, band),
                   let bodyOvl = crop(img.overlay, 0, band, W, H) {
                    for (layer, image) in [(shadowView.layer, img.shadow), (overlayView.layer, bodyOvl), (bandOverlay.layer, bandOvl)] {
                        layer?.contents = image
                        layer?.contentsScale = CGFloat(scale)
                    }
                    bodyFill.setMask(bodyMask, scale: scale)
                    bandLeft.setMask(leftMask, scale: scale)
                    bandRight.setMask(rightMask, scale: scale)
                    bandStrip.setMask(nil, scale: scale)    // the strip is fully painted
                    renderedPads = (img.padX, img.padBelow)
                    renderedKey = key
                    log("rendered chrome \(W)x\(H) @\(scale)x dark=\(key.dark) active=\(key.active)")
                }
            }
        }
        let x = f.minX.rounded(), bottom = f.minY.rounded()
        let bodyFrame = NSRect(x: x, y: bottom - CGFloat(H), width: CGFloat(W), height: CGFloat(H))
        let shadowFrame = NSRect(x: x - CGFloat(renderedPads.x), y: bottom - CGFloat(H + renderedPads.below),
                                 width: CGFloat(W + 2 * renderedPads.x), height: CGFloat(band + H + renderedPads.below))
        if shadow.frame != shadowFrame { shadow.setFrame(shadowFrame, display: true) }
        if body.frame != bodyFrame { body.setFrame(bodyFrame, display: true) }
        // Explicit frames: these subviews start at .zero, which autoresizing would keep at zero.
        let bounds = NSRect(origin: .zero, size: bodyFrame.size)
        for v in [bodyFill, overlayView] as [NSView] where v.frame != bounds { v.frame = bounds }
        shadowView.frame = NSRect(origin: .zero, size: shadowFrame.size)
        let px = CGFloat(renderedPads.x), top = shadowFrame.height        // band top edge (non-flipped y)
        let bandFrame = NSRect(x: px, y: top - CGFloat(band), width: CGFloat(W), height: CGFloat(band))
        if bandOverlay.frame != bandFrame { bandOverlay.frame = bandFrame }
        // Corner patches: the band rows above the strip; the strip: the band's bottom `sh` rows.
        let leftF = NSRect(x: px, y: top - CGFloat(band - sh), width: CGFloat(cw), height: CGFloat(band - sh))
        let rightF = NSRect(x: px + CGFloat(W - cw), y: leftF.minY, width: CGFloat(cw), height: CGFloat(band - sh))
        let stripF = NSRect(x: px, y: top - CGFloat(band), width: CGFloat(W), height: CGFloat(sh))
        for (v, fr) in [(bandLeft, leftF), (bandRight, rightF), (bandStrip, stripF)] where v.frame != fr { v.frame = fr }
        for p in fillPatches { p.setActive(key.active) }
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
        for p in fillPatches { p.setFill(color) }
        CATransaction.commit()
    }

    // MARK: Show / hide

    private func show() {
        guard !isShown else { return }
        logState("show")
        isShown = true
        fadeGeneration += 1
        // Make sure frames, masks and content are committed before anything becomes visible.
        rootView.layoutSubtreeIfNeeded()
        shadowRoot.layoutSubtreeIfNeeded()
        body.displayIfNeeded(); shadow.displayIfNeeded()
        fade(to: 1)
    }

    private func hide() {
        heightAnimation?.invalidate(); heightAnimation = nil
        waitingForSample = false
        guard isShown else { return }
        logState("hide")
        isShown = false
        fadeGeneration += 1
        let gen = fadeGeneration
        fade(to: 0)
        // Order out after the fade. If the main thread is late, the panel is already invisible:
        // the opacity's final value was set immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == gen, !self.isShown else { return }
                self.body.orderOut(nil)
                self.shadow.orderOut(nil)
            }
        }
    }

    /// BUG-001 (c): stall-proof fade. The layers' model opacity is set to the target immediately;
    /// the visible transition is a Core Animation animation run by the render server, so neither a
    /// busy main thread nor an interrupted animation can leave the panel half transparent.
    private func fade(to target: Float) {
        for v in [rootView, shadowRoot] as [NSView] {
            guard let layer = v.layer else { v.alphaValue = CGFloat(target); continue }
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.removeAnimation(forKey: "fade")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = target
            CATransaction.commit()
            guard fadeDuration > 0, from != target else { continue }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from; a.toValue = target
            a.duration = fadeDuration
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: "fade")
        }
    }
}

/// One fill area: the material (fallback) or Finder's sampled solid colour, masked by an image.
private final class FillPatch: NSView {
    private let effect = NSVisualEffectView()
    private let solid = CALayer()
    private let solidMask = CALayer()
    private var maskImage: CGImage?
    private var maskScale = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)
        solid.isHidden = true
        solidMask.contentsGravity = .resize
        layer?.addSublayer(solid)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effect.frame = bounds
        solid.frame = bounds
        solidMask.frame = solid.bounds
        CATransaction.commit()
    }

    override var frame: NSRect { didSet { needsLayout = true; layoutSubtreeIfNeeded() } }

    /// nil = fully painted.
    func setMask(_ image: CGImage?, scale: Int) {
        maskImage = image; maskScale = scale
        if let image {
            effect.maskImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / CGFloat(scale),
                                                                    height: CGFloat(image.height) / CGFloat(scale)))
            solidMask.contents = image
            solidMask.contentsScale = CGFloat(scale)
            solid.mask = solidMask
        } else {
            effect.maskImage = nil
            solid.mask = nil
        }
    }

    /// nil = material fallback.
    func setFill(_ color: CGColor?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let color { solid.backgroundColor = color }
        solid.isHidden = color == nil
        effect.isHidden = color != nil
        CATransaction.commit()
    }

    /// Finder's background looks the same in both states (measured); keep the material active so
    /// it never switches to a different rendering.
    func setActive(_ active: Bool) {
        if effect.state != .active { effect.state = .active }
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
