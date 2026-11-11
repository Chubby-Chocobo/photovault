import Foundation

/// Whether the menu bar popup is open, from what its window says each time something about it changes.
/// The popup counts as open while its window is on screen, or is key: being ordered in and out is the main
/// signal, and key status covers a window that becomes key before it reports itself visible. Only a real
/// change is passed on, so a repeated or late report never opens the popup a second time (which would
/// restart its height) or closes it while it is still showing.
public struct PopupOpenState: Equatable, Sendable {
    public private(set) var isOpen: Bool?

    public init() {}

    /// The window is now `isVisible` and `isKey`. Returns the new open state when it changed, else nil.
    public mutating func update(isVisible: Bool, isKey: Bool) -> Bool? {
        let open = isVisible || isKey
        guard open != isOpen else { return nil }
        isOpen = open
        return open
    }
}
