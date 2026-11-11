import Foundation

/// The size of the menu bar popup. While the engine runs, the content area has one height and scrolls inside
/// it, so a card, a banner or a line that comes and goes never moves the header or the action rows below.
public enum PopoverLayout {
    /// The popup is this wide, as in the menu-bar mockup.
    public static let width: Double = 360
    /// The running content area is this tall when the screen has room.
    public static let runningContentHeight: Double = 520
    /// Room the screen must keep for the popup's padding and the action rows under the content.
    static let actionsAllowance: Double = 280
    /// The content area is never shorter than this, even on a very small screen.
    static let minimumContentHeight: Double = 240

    /// The running content height on a screen whose visible area (without the menu bar and the Dock) is
    /// `visibleScreenHeight` tall: 520 pt, or less when the screen cannot fit that and the action rows.
    public static func runningContentHeight(visibleScreenHeight: Double) -> Double {
        min(runningContentHeight, max(minimumContentHeight, visibleScreenHeight - actionsAllowance))
    }
}
