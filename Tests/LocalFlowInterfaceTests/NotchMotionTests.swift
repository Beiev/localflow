import XCTest
import AppKit
import SwiftUI
import QuartzCore

@MainActor
private final class SlowLayoutView: NSView {
    var nextLayoutDelay: TimeInterval = 0
    var didDelay = false
    override func layout() {
        super.layout()
        if nextLayoutDelay > 0 {
            let delay = nextLayoutDelay; nextLayoutDelay = 0
            didDelay = true
            Thread.sleep(forTimeInterval: delay)
        }
    }
}

final class NotchMotionTests: XCTestCase {
    func testRapidReversalPreservesPositionAndVelocity() {
        var motion = NotchMotion()
        motion.move(to: 1, at: 10)
        for (time, target) in [(10.08, 0.0), (10.14, 1.0), (10.19, 0.0), (10.24, 1.0)] {
            let before = motion.sample(at: time)
            motion.move(to: target, at: time)
            let after = motion.sample(at: time)
            XCTAssertEqual(before.position, after.position, accuracy: 0.000001)
            XCTAssertEqual(before.velocity, after.velocity, accuracy: 0.000001)
        }
        XCTAssertEqual(motion.sample(at: 12).position, 1)
        XCTAssertEqual(motion.sample(at: 12).velocity, 0)
    }
    func testRapidDoubleTapClosesWithoutOvershootOrReopening() {
        var motion = NotchMotion()
        motion.move(to: 1, at: 0)
        motion.move(to: 0, at: 0.07)
        for frame in 0...180 {
            let sample = motion.sample(at: 0.07 + Double(frame) / 120)
            XCTAssertTrue((0...1).contains(sample.position))
        }
        XCTAssertEqual(motion.sample(at: 1).position, 0)
        XCTAssertEqual(motion.sample(at: 8).position, 0)
    }
    func testRepeatedHideIsIdempotentAndOldCompletionCannotHideReopenedPanel() {
        var visibility = OverlayVisibility()
        XCTAssertNil(visibility.request(false))
        XCTAssertNotNil(visibility.request(true))
        XCTAssertNil(visibility.request(true))
        let closing = visibility.request(false)!
        XCTAssertNil(visibility.request(false))
        XCTAssertTrue(visibility.canFinishHiding(revision: closing))
        XCTAssertNotNil(visibility.request(true))
        XCTAssertFalse(visibility.canFinishHiding(revision: closing))
        let nextClose = visibility.request(false)!
        XCTAssertFalse(visibility.canFinishHiding(revision: closing))
        XCTAssertTrue(visibility.canFinishHiding(revision: nextClose))
    }
    func testCornersStayCurvedThroughoutRevealAndTopologyIsStable() {
        let size = CGSize(width: 380, height: 180)
        var expected: [CGPathElementType]?
        for progress in [0.0, 0.01, 0.05, 0.15, 0.3, 0.5, 0.8, 1] {
            let path = NotchGeometry.path(size: size, notchWidth: 185, topInset: 32, progress: progress)
            var types: [CGPathElementType] = []
            path.applyWithBlock { types.append($0.pointee.type) }
            if let expected { XCTAssertEqual(types, expected) } else { expected = types }
            XCTAssertEqual(types.filter { $0 == .addCurveToPoint }.count, 6)
            let box = path.boundingBoxOfPath
            XCTAssertFalse(path.contains(CGPoint(x: box.minX + 0.05, y: box.maxY - 0.05)), "A square lower corner appeared at \(progress)")
            XCTAssertTrue(path.contains(CGPoint(x: size.width / 2, y: box.maxY - 0.1)))
        }
    }
    @MainActor func testNativePanelSurvivesStaleCloseAndFinallyDisappears() async throws {
        let controller = OverlayController()
        controller.show(content: AnyView(Text("Тест анимации")))
        XCTAssertTrue(controller.isPresented)
        try await Task.sleep(for: .milliseconds(80))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let contour = try XCTUnwrap(controller.presentedContourBounds)
            XCTAssertGreaterThan(contour.height, 32)
            XCTAssertLessThan(contour.height, 170, "The native contour must have intermediate frames, not jump to its final size")
        }
        controller.hide()
        try await Task.sleep(for: .milliseconds(80))
        controller.show(content: AnyView(Text("Тест анимации")))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPresented)
        controller.hide()
        try await Task.sleep(for: .milliseconds(350))
        controller.hide() // Must not extend the closing animation.
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(controller.isPresented)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.isPresented)
    }
    @MainActor func testHiddenPreparationReusesContentWithoutPresentingPanel() async throws {
        let controller = OverlayController()
        var builds = 0
        func content() -> AnyView { builds += 1; return AnyView(Text("Подготовленная панель")) }
        controller.prepare(content: content())
        controller.prepare(content: content())
        XCTAssertEqual(builds, 1)
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(controller.isPresented)
        controller.show(content: content())
        XCTAssertEqual(builds, 1, "Opening must reuse the prepared hosting/text views")
        XCTAssertTrue(controller.isPresented)
        controller.hide()
        try await Task.sleep(for: .milliseconds(800))
    }
    @MainActor func testDeferredWorkWaitsForLatestOpeningAndCanBeCancelled() async throws {
        let controller = OverlayController()
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : NotchMotion.duration
        controller.show(content: AnyView(Text("Проверка отложенного распознавания")))
        var didStartWork = false
        let work = Task { @MainActor in
            try await controller.waitForOpening()
            didStartWork = true
        }
        try await Task.sleep(for: .seconds(duration * 0.5))
        XCTAssertFalse(didStartWork)
        controller.hide()
        controller.show(content: AnyView(EmptyView()))
        try await Task.sleep(for: .seconds(duration * 0.65))
        XCTAssertFalse(didStartWork, "The old reveal's deadline must not release work into a newer opening")
        try await work.value
        XCTAssertTrue(didStartWork)
        XCTAssertFalse(controller.isOpening)
        controller.hide()
        controller.show(content: AnyView(EmptyView()))
        let cancelled = Task { @MainActor in try await controller.waitForOpening() }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled startup must not resume deferred work") }
        catch is CancellationError { }
        controller.hide()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(controller.isPresented)
    }
    @MainActor func testOpeningIsSubmittedBeforeMainThreadBecomesBusy() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("Requires the full animation") }
        let controller = OverlayController()
        controller.prepare(content: AnyView(Text("Проверка первого кадра")))
        controller.show(content: AnyView(EmptyView()))
        // Simulate synchronous startup work without giving AppKit another turn
        // to commit a pending transaction. The compositor must already be moving.
        Thread.sleep(forTimeInterval: 0.08)
        let contour = try XCTUnwrap(controller.presentedContourBounds)
        XCTAssertGreaterThan(contour.height, 32)
        XCTAssertLessThan(contour.height, 170)
        controller.hide()
    }
    @MainActor func testCloseDuringEntranceDoesNotAuthorizeMicrophoneStartup() async throws {
        let controller = OverlayController()
        controller.show(content: AnyView(Text("Готовлю запись…")))
        let start = Task { @MainActor in try await controller.waitForOpening() }
        try await Task.sleep(for: .milliseconds(40))
        controller.hide()
        let shouldCapture = try await start.value
        XCTAssertFalse(shouldCapture, "A quick second press must not start the microphone after closing")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(controller.isPresented)
    }
    @MainActor func testPendingWindowLayoutCannotConsumeTheEntranceClock() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("Requires the full animation") }
        // Reproduce the real failure: another window has pending layout which
        // AppKit will drain during the animation transaction's commit.
        let window = NotchPanel(contentRect: NSRect(x: 10, y: 10, width: 100, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = false; window.ignoresMouseEvents = true; window.animationBehavior = .none
        let busy = SlowLayoutView(); busy.wantsLayer = true; window.contentView = busy
        window.orderFrontRegardless()
        CATransaction.flush()
        defer { window.orderOut(nil) }
        let controller = OverlayController()
        controller.prepare(content: AnyView(Text("Готовлю запись…")))
        CATransaction.flush()
        busy.nextLayoutDelay = 0.24; busy.needsLayout = true
        controller.show(content: AnyView(EmptyView()))
        XCTAssertTrue(busy.didDelay, "Fixture must exercise pending layout during the commit")
        try await Task.sleep(for: .milliseconds(80))
        let contour = try XCTUnwrap(controller.presentedContourBounds)
        XCTAssertGreaterThan(contour.height, 32)
        XCTAssertLessThan(contour.height, 125, "Pending layout must not skip the first 240 ms of the reveal")
        controller.hide()
        try await Task.sleep(for: .milliseconds(800))
    }
    @MainActor func testRepeatedShowRestoresAnExternallyOrderedOutWindow() async throws {
        let controller = OverlayController()
        controller.show(content: AnyView(Text("Recording")))
        try await Task.sleep(for: .milliseconds(800))
        let window = try XCTUnwrap(NSApp.window(withWindowNumber: try XCTUnwrap(controller.windowNumber)))
        window.orderOut(nil)
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.isPresented)
        controller.show(content: AnyView(Text("Recording")))
        XCTAssertTrue(controller.isPresented, "A show request must repair the actual window, not only check the logical flag")
        controller.hide()
        try await Task.sleep(for: .milliseconds(800))
    }
    @MainActor func testRecordingSurfaceKeepsItsDrawingLayersAcrossPresentations() async throws {
        let controller = OverlayController()
        for _ in 0..<3 {
            controller.show(content: AnyView(Text("Recording")))
            try await Task.sleep(for: .milliseconds(800))
            let window = try XCTUnwrap(NSApp.window(withWindowNumber: try XCTUnwrap(controller.windowNumber)))
            let root = try XCTUnwrap(window.contentView?.layer)
            XCTAssertTrue(root.sublayers?.contains { $0 is CAShapeLayer } == true, "The silhouette must be attached to the window's current render tree")
            controller.hide()
            try await Task.sleep(for: .milliseconds(800))
        }
    }
    @MainActor func testRecordingPanelSurvivesHidingTheApplication() async throws {
        let controller = OverlayController()
        controller.show(content: AnyView(Text("Recording")))
        try await Task.sleep(for: .milliseconds(800))
        NSApp.hide(nil)
        defer { NSApp.unhideWithoutActivation() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.isPresented, "Hiding the archive app must not hide an active recording overlay")
        controller.show(content: AnyView(Text("Recording")))
        XCTAssertTrue(controller.isPresented)
        controller.hide()
        try await Task.sleep(for: .milliseconds(800))
    }
    @MainActor func testHiddenArchiveCanOpenAndCloseRecordingPanelWithoutActivation() async throws {
        let controller = OverlayController()
        controller.prepare(content: AnyView(Text("Recording")))
        NSApp.hide(nil)
        defer { NSApp.unhideWithoutActivation() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(NSApp.isHidden, "The test must start with a hidden application")
        let keyWindow = NSApp.keyWindow
        for _ in 0..<2 {
            controller.show(content: AnyView(EmptyView()))
            let ready = try await controller.waitForOpening()
            XCTAssertTrue(ready, "A shortcut from a hidden app must actually present the panel")
            XCTAssertTrue(controller.isPresented)
            XCTAssertTrue(NSApp.isHidden, "Showing dictation must not unhide the archive")
            XCTAssertTrue(NSApp.keyWindow === keyWindow, "The panel must not take keyboard focus")
            controller.hide()
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertFalse(controller.isPresented)
        }
    }
}
