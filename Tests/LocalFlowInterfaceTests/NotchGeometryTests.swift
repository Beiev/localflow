import XCTest
import AppKit

final class NotchGeometryTests: XCTestCase {
    @MainActor func testPanelStaysAttachedToPhysicalTopIncludingOnSecondaryScreen() {
        for screen in [NSRect(x: 0, y: 0, width: 1512, height: 982), NSRect(x: -1920, y: 240, width: 1920, height: 1080)] {
            let frame = NotchGeometry.frame(screen: screen, height: 180)
            let panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let constrained = panel.constrainFrameRect(frame, to: NSScreen.main)
            XCTAssertEqual(constrained.maxY, screen.maxY)
            XCTAssertEqual(constrained.midX, screen.midX)
            XCTAssertEqual(constrained.width, 380)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
        }
    }
}
