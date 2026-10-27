import AppKit
import SwiftUI
import QuartzCore
import OSLog

/// A fixed-size native surface. Only compositor-owned paths/opacity animate;
/// incoming meter/transcript updates cannot reset or relayout the transition.
@MainActor
final class NotchSurface: NSView {
    private static let animationLog = Logger(subsystem: "com.beiev.localflow", category: "notch-animation")
    private let silhouette = CAShapeLayer()
    private let contentMask = CAShapeLayer()
    private let contentContainer = NSView()
    private let host: NSHostingView<AnyView>
    private var motion = NotchMotion()
    private var notchWidth: CGFloat = 180
    private var topInset: CGFloat = 32
    var presentedContourBounds: CGRect? { silhouette.presentation()?.path?.boundingBoxOfPath }

    init(content: AnyView) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        wantsLayer = true
        silhouette.fillColor = NSColor.black.cgColor
        layer?.addSublayer(silhouette)
        contentContainer.wantsLayer = true
        contentContainer.layer?.mask = contentMask
        contentMask.fillColor = NSColor.black.cgColor
        addSubview(contentContainer)
        contentContainer.addSubview(host)
        host.wantsLayer = true
        contentContainer.layer?.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(size: NSSize, notchWidth: CGFloat, topInset: CGFloat) {
        self.notchWidth = notchWidth; self.topInset = topInset
        frame.size = size
        // Layout is performed once per presentation, outside any animation transaction.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        silhouette.contentsScale = scale; contentMask.contentsScale = scale
        silhouette.frame = bounds
        contentContainer.frame = bounds
        contentMask.frame = bounds
        host.frame = NSRect(x: 18, y: 12, width: size.width - 36, height: size.height - topInset - 20)
        let path = path(at: motion.sample(at: CACurrentMediaTime()).position)
        silhouette.path = path; contentMask.path = path
        CATransaction.commit()
        layoutSubtreeIfNeeded()
    }
    func prepareContents() {
        // SwiftUI/TextKit's first layout and display can be expensive. Finish them
        // before starting the compositor clock, including on the first opening.
        layoutSubtreeIfNeeded()
        displayIfNeeded()
    }
    private func path(at progress: Double) -> CGPath {
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        return NotchGeometry.path(size: bounds.size, notchWidth: notchWidth, topInset: topInset, progress: progress).copy(using: &flip)!
    }
    @discardableResult
    func setExpanded(_ expanded: Bool, reduceMotion: Bool) -> Double {
        let preparationStartedAt = CACurrentMediaTime()
        if expanded {
            prepareContents()
            // flush() runs AppKit's commit handlers for ALL windows. Starting
            // the clock before it let the archive's pending SwiftUI layout eat
            // the entrance (187 ms in the startup trace). Drain it while the
            // contour is still collapsed, then create the timed animation.
            CATransaction.flush()
        }
        let now = CACurrentMediaTime()
        let duration = reduceMotion ? 0.12 : NotchMotion.duration
        motion.move(to: expanded ? 1 : 0, at: now, duration: duration)
        let count = Int(ceil(duration * 120))
        let samples = (0...count).map { index -> Double in
            if index == count { return motion.target }
            return motion.sample(at: now + duration * Double(index) / Double(count)).position
        }
        let paths = samples.map { path(at: $0) }
        let opacity = samples.map { progress -> Float in
            let fraction = min(1, max(0, (progress - 0.18) / 0.7))
            return Float(fraction * fraction * (3 - 2 * fraction))
        }
        let refreshRate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        silhouette.path = paths.last; contentMask.path = paths.last
        contentContainer.layer?.opacity = expanded ? 1 : 0
        func animation(_ key: String, values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values; animation.duration = duration
            animation.calculationMode = .linear
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            // A 120 Hz sample array does not request 120 Hz presentation. Ask
            // the compositor to match this display, including ProMotion.
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, refreshRate), maximum: refreshRate, preferred: refreshRate)
            animation.beginTime = now
            return animation
        }
        silhouette.add(animation("path", values: paths), forKey: "reveal")
        contentMask.add(animation("path", values: paths), forKey: "reveal")
        // Animate our own container; NSHostingView owns and may update its layer.
        contentContainer.layer?.add(animation("opacity", values: opacity), forKey: "reveal")
        CATransaction.commit()
        // Submit now, before microphone startup or a SwiftUI archive refresh can
        // consume the first frames of an animation still waiting in a transaction.
        CATransaction.flush()
        if expanded {
            Self.animationLog.info("Entrance preparation: \(now - preparationStartedAt) s; timed commit: \(CACurrentMediaTime() - now) s")
        }
        return duration
    }
}

@MainActor
final class OverlayController {
    private static let presentationLog = Logger(subsystem: "com.beiev.localflow", category: "notch-presentation")
    private var panel: NSPanel?
    private var surface: NotchSurface?
    private var hideTask: Task<Void, Never>?
    private var visibility = OverlayVisibility()
    private var openingEndsAt: CFTimeInterval = 0
    var onVisibilityChange: ((Bool) -> Void)?
    var isVisible: Bool { visibility.isVisible }
    var isPresented: Bool { panel?.isVisible ?? false }
    var windowNumber: Int? { panel?.windowNumber }
    var presentedContourBounds: CGRect? { surface?.presentedContourBounds }
    var isOpening: Bool { isVisible && CACurrentMediaTime() < openingEndsAt }

    /// Build/layout the hidden surface during idle time, without activating a
    /// window, opening the microphone or loading a recognition model.
    func prepare(content: @autoclosure () -> AnyView) {
        if panel == nil {
            let panel = NotchPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            // Dictation belongs to the foreground app's text field. Hiding the
            // archive with Cmd-H must not hide this independent status panel.
            panel.canHide = false
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            // Otherwise AppKit may animate orderFront as a utility window while
            // the contour is also unfolding, producing two competing entrances.
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = true
            let surface = NotchSurface(content: content())
            panel.contentView = surface
            self.panel = panel; self.surface = surface
        }
        guard let panel, let surface,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return
        }
        let inset = max(12, screen.safeAreaInsets.top)
        let frame = NotchGeometry.frame(screen: screen.frame, height: 148 + inset)
        // Reposition a stale window after screen changes, but do not relayout a
        // healthy visible surface or interrupt its ongoing motion on reversal.
        if !panel.isVisible || panel.frame != frame {
            panel.setFrame(frame, display: false)
            surface.configure(size: frame.size, notchWidth: NotchGeometry.notchWidth(screen: screen), topInset: inset)
            surface.prepareContents()
        }
    }
    func show(content: @autoclosure () -> AnyView) {
        let changed = visibility.request(true) != nil
        hideTask?.cancel()
        if changed { onVisibilityChange?(true) }
        let wasPresented = isPresented
        prepare(content: content())
        guard let panel, let surface, !panel.frame.isEmpty else {
            _ = visibility.request(false); onVisibilityChange?(false); return
        }
        // Always reconcile the native window. A logical "visible" flag cannot
        // tell us whether AppKit ordered it out, hid it or moved it offscreen.
        panel.orderFrontRegardless()
        if changed || !wasPresented {
            let duration = surface.setExpanded(true, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            openingEndsAt = CACurrentMediaTime() + duration
        }
        Self.presentationLog.info("Requested recording panel: window=\(panel.windowNumber), visible=\(panel.isVisible), onActiveSpace=\(panel.isOnActiveSpace), appHidden=\(NSApp.isHidden), frame=\(NSStringFromRect(panel.frame), privacy: .public)")
    }
    /// Initial microphone startup and subsequent UI/recognition work wait here.
    /// A close/reopen reuses the same waiter, following the latest entrance.
    @discardableResult
    func waitForOpening() async throws -> Bool {
        while isOpening {
            try await Task.sleep(for: .seconds(max(0, openingEndsAt - CACurrentMediaTime())))
            try Task.checkCancellation()
            // Re-read the deadline: a quick close/reopen can start another reveal.
        }
        try Task.checkCancellation()
        return isVisible && isPresented
    }
    func hide() {
        guard let revision = visibility.request(false) else { return }
        onVisibilityChange?(false)
        let duration = surface?.setExpanded(false, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) ?? 0
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, visibility.canFinishHiding(revision: revision) else { return }
            panel?.orderOut(nil)
        }
    }
}
