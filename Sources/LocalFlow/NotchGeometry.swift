import AppKit

/// Physical screen coordinates, including the menu bar/notch, not visibleFrame.
enum NotchGeometry {
    static func frame(screen: NSRect, width: CGFloat = 380, height: CGFloat = 180) -> NSRect {
        let width = min(width, screen.width)
        return NSRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }
    static func notchWidth(screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return 180 }
        return max(140, right.minX - left.maxX)
    }
}

/// AppKit otherwise moves the panel below the menu bar, leaving a visible seam
/// and duplicating the notch-height padding inside the panel.
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NotchGeometry {
    /// Every sample has identical path topology and curved corners. The entire
    /// surface, including its content, is masked by this path (never by a rectangle).
    static func path(size: CGSize, notchWidth: CGFloat, topInset: CGFloat, progress: Double) -> CGPath {
        let p = CGFloat(min(1, max(0, progress)))
        let neck = min(notchWidth, size.width)
        let width = neck + (size.width - neck) * p
        let x = (size.width - width) / 2
        let height = topInset + (size.height - topInset) * p
        let top = max(0, topInset - 2)
        let side = (width - neck) / 2
        let shoulder = min(10, side / 2)
        let upperRadius = min(18, side / 2, (height - top) / 2)
        let bottomX = min(22, width / 2)
        let bottomY = min(22, (height - top) / 2)
        let left = (size.width - neck) / 2, right = left + neck
        let edge = x + width
        let path = CGMutablePath()
        // Coordinates are top-down; the native surface transforms them to AppKit coordinates.
        path.move(to: CGPoint(x: left, y: 0))
        path.addLine(to: CGPoint(x: right, y: 0))
        path.addLine(to: CGPoint(x: right, y: top - shoulder))
        path.addCurve(to: CGPoint(x: right + shoulder, y: top), control1: CGPoint(x: right, y: top - shoulder * 0.45), control2: CGPoint(x: right + shoulder * 0.45, y: top))
        path.addLine(to: CGPoint(x: edge - upperRadius, y: top))
        path.addCurve(to: CGPoint(x: edge, y: top + upperRadius), control1: CGPoint(x: edge - upperRadius * 0.45, y: top), control2: CGPoint(x: edge, y: top + upperRadius * 0.45))
        path.addLine(to: CGPoint(x: edge, y: height - bottomY))
        path.addCurve(to: CGPoint(x: edge - bottomX, y: height), control1: CGPoint(x: edge, y: height - bottomY * 0.45), control2: CGPoint(x: edge - bottomX * 0.45, y: height))
        path.addLine(to: CGPoint(x: x + bottomX, y: height))
        path.addCurve(to: CGPoint(x: x, y: height - bottomY), control1: CGPoint(x: x + bottomX * 0.45, y: height), control2: CGPoint(x: x, y: height - bottomY * 0.45))
        path.addLine(to: CGPoint(x: x, y: top + upperRadius))
        path.addCurve(to: CGPoint(x: x + upperRadius, y: top), control1: CGPoint(x: x, y: top + upperRadius * 0.45), control2: CGPoint(x: x + upperRadius * 0.45, y: top))
        path.addLine(to: CGPoint(x: left - shoulder, y: top))
        path.addCurve(to: CGPoint(x: left, y: top - shoulder), control1: CGPoint(x: left - shoulder * 0.45, y: top), control2: CGPoint(x: left, y: top - shoulder * 0.45))
        path.closeSubpath()
        return path
    }
}
