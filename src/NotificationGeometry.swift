import Cocoa

extension NSScreen {
    /// The CGDirectDisplayID for this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}

/// Pure geometry calculations for notification positioning.
/// All methods are static and take explicit screen parameters so they can be unit-tested
/// without a live display.
struct NotificationGeometry {

    /// Returns the NSScreen whose frame contains the given AX coordinate point,
    /// or the main screen as fallback.
    static func screen(containing point: CGPoint) -> NSScreen? {
        // AX coordinates use top-left origin; NSScreen.frame uses bottom-left.
        // Convert: screenY = primaryHeight - point.y
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            return NSScreen.main
        }
        let converted = CGPoint(x: point.x, y: primaryHeight - point.y)
        return NSScreen.screens.first(where: { $0.frame.contains(converted) }) ?? NSScreen.main
    }

    /// Compute the initial padding and effective position, correcting for off-screen placement.
    static func initialData(
        screenWidth: CGFloat,
        notifSize: CGSize,
        position: CGPoint
    ) -> (effectivePosition: CGPoint, padding: CGFloat) {
        var effectivePosition = position
        let padding: CGFloat

        if position.x + notifSize.width > screenWidth {
            padding = 16.0
            effectivePosition.x = screenWidth - notifSize.width - padding
        } else {
            let rightEdge = position.x + notifSize.width
            padding = screenWidth - rightEdge
        }

        return (effectivePosition, padding)
    }

    /// Calculate the new (x, y) offset to move a notification to the desired position.
    ///
    /// - Parameters:
    ///   - target: The desired notification position.
    ///   - windowSize: The AX window size.
    ///   - notifSize: The notification banner size.
    ///   - origin: The cached initial position of the banner.
    ///   - padding: The cached initial padding from screen edge.
    ///   - screenFrame: The full frame of the target screen (in CG coordinates).
    ///   - visibleFrame: The visible frame (excluding menu bar / Dock) in CG coordinates.
    ///   - paddingAboveDock: Extra padding above the Dock.
    static func newPosition(
        for target: NotificationPosition,
        windowSize: CGSize,
        notifSize: CGSize,
        origin: CGPoint,
        padding: CGFloat,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        paddingAboveDock: CGFloat
    ) -> (x: CGFloat, y: CGFloat) {
        let newX: CGFloat
        let newY: CGFloat

        switch target {
        case .topLeft, .middleLeft, .bottomLeft:
            newX = screenFrame.minX + padding - origin.x
        case .topMiddle, .bottomMiddle, .deadCenter:
            newX = screenFrame.minX + (windowSize.width - notifSize.width) / 2 - origin.x
        case .topRight, .middleRight, .bottomRight:
            newX = 0
        }

        let dockSize = screenFrame.height - visibleFrame.height

        switch target {
        case .topLeft, .topMiddle, .topRight:
            newY = 0
        case .middleLeft, .middleRight, .deadCenter:
            newY = (windowSize.height - notifSize.height) / 2 - dockSize
        case .bottomLeft, .bottomMiddle, .bottomRight:
            newY = windowSize.height - notifSize.height - dockSize - paddingAboveDock
        }

        return (newX, newY)
    }
}
