import Foundation

/// The size of the menu bar popup. While the engine runs, the content area is as tall as what it shows, up
/// to what the screen can hold, and scrolls past that. While the popup stays open it only grows (see
/// `PopoverContentHeight`), so a card or banner that leaves for a moment never pulls the action rows up and
/// back down. The lines that change every second keep one-line slots, so they never change the height.
public enum PopoverLayout {
    /// The popup is this wide, as in the menu-bar mockup.
    public static let width: Double = 360
    /// Room for what surrounds the content and the action rows: the popup's padding, the divider and the
    /// gaps beside it, and a margin above the screen's bottom edge.
    static let chromeAllowance: Double = 60
    /// The content area may always be this tall, even on a very small screen.
    static let minimumContentLimit: Double = 240

    /// The tallest the running content may be on a screen whose visible area (without the menu bar and the
    /// Dock) is `visibleScreenHeight` tall, when the action rows below it, the NAS folder list included when
    /// it is open, are `actionsHeight` tall.
    public static func contentLimit(visibleScreenHeight: Double, actionsHeight: Double) -> Double {
        max(minimumContentLimit, visibleScreenHeight - actionsHeight - chromeAllowance)
    }
}

/// The height of the popup's running content area. While the popup is open it follows the tallest content
/// measured since it opened, so it grows but never shrinks; when the popup opens it starts again from what
/// the content needs now. While the popup is closed it follows the content, so it opens at the right size.
/// It never goes past the limit the screen sets; content taller than that scrolls.
public struct PopoverContentHeight: Equatable, Sendable {
    public private(set) var isOpen = false
    /// The content's height at the last measurement.
    private var latest: Double = 0
    /// The tallest content measured since the popup opened (the latest one while it is closed).
    private var tallest: Double = 0

    public init() {}

    /// The popup opened: fit what it shows now.
    public mutating func opened() {
        isOpen = true
        tallest = latest
    }

    /// The popup closed: follow the content until it opens again.
    public mutating func closed() {
        isOpen = false
        tallest = latest
    }

    /// The content now needs `height` points.
    public mutating func measured(_ height: Double) {
        latest = max(0, height)
        tallest = isOpen ? max(tallest, latest) : latest
    }

    /// The content area's height under `limit`, or nil before anything has been measured.
    public func height(limit: Double) -> Double? {
        tallest > 0 ? min(tallest, limit) : nil
    }
}
