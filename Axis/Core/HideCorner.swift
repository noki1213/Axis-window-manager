import AppKit

/// Where a window goes while it is hidden: pushed past a bottom corner of its
/// screen with a single point left on screen, since macOS pulls a window that
/// is entirely off screen back into view.
enum HideCorner {
    case bottomLeft
    case bottomRight

    /// The bottom corner facing away from any neighbouring screen, so a hidden
    /// window does not reach into the next display.
    static func best(for screen: NSScreen) -> HideCorner {
        let hasScreenOnRight = NSScreen.screens.contains { other in
            other != screen && other.frame.minX >= screen.frame.maxX - 10
        }
        return hasScreenOnRight ? .bottomLeft : .bottomRight
    }

    /// The window's top-left position in Accessibility coordinates (origin at
    /// the primary display's top-left, y growing downward).
    func position(forWindowWidth width: CGFloat, on screen: NSScreen) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let visibleFrame = screen.visibleFrame
        // The window's top edge sits 1pt above the visible area's bottom edge.
        let y = primaryHeight - visibleFrame.minY - 1
        switch self {
        case .bottomLeft:
            return CGPoint(x: visibleFrame.minX - width + 1, y: y)
        case .bottomRight:
            return CGPoint(x: visibleFrame.maxX - 1, y: y)
        }
    }
}
