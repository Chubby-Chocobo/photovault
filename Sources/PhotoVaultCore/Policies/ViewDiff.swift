import Foundation

/// A shortcut the view rules want to exist.
public struct DesiredShortcut: Hashable, Sendable {
    public var assetKey: AssetKey
    public var view: ViewKind
    public var parentLogical: String
    /// Remote id of the primary resource; nil until that resource is `done`.
    public var targetId: String?

    public init(assetKey: AssetKey, view: ViewKind, parentLogical: String, targetId: String?) {
        self.assetKey = assetKey
        self.view = view
        self.parentLogical = parentLogical
        self.targetId = targetId
    }
}

public enum ViewOperation: Hashable, Sendable {
    case trash(view: ViewKind, assetKey: AssetKey)
    case move(view: ViewKind, assetKey: AssetKey, toParentLogical: String)
    case create(DesiredShortcut)
}

/// Desired versus current shortcuts of one destination (8.13).
public enum ViewDiff {
    /// Operations ordered trash, then move, then create; each group sorted by view and asset key.
    /// `userRemoved` shortcuts are never touched. Shortcuts being trashed are left to finish.
    public static func operations(desired: [DesiredShortcut], current: [ShortcutRecord]) -> [ViewOperation] {
        var currentByID: [Slot: ShortcutRecord] = [:]
        for record in current { currentByID[Slot(view: record.view, assetKey: record.assetKey)] = record }
        var desiredByID: [Slot: DesiredShortcut] = [:]
        for item in desired { desiredByID[Slot(view: item.view, assetKey: item.assetKey)] = item }

        var trashes: [Slot] = []
        var moves: [(Slot, String)] = []
        var creates: [DesiredShortcut] = []

        for (slot, item) in desiredByID {
            guard let record = currentByID[slot] else {
                if item.targetId != nil { creates.append(item) }
                continue
            }
            switch record.state {
            case .userRemoved, .trashPending:
                continue
            case .trashed, .pending:
                if item.targetId != nil { creates.append(item) }
            case .done, .movePending, .failed:
                if let wanted = item.targetId, let have = record.targetId, wanted != have {
                    trashes.append(slot)
                    creates.append(item)
                } else if record.parentLogical != item.parentLogical {
                    moves.append((slot, item.parentLogical))
                }
            }
        }
        for (slot, record) in currentByID where desiredByID[slot] == nil {
            switch record.state {
            case .done, .movePending, .failed, .pending: trashes.append(slot)
            case .userRemoved, .trashPending, .trashed: continue
            }
        }

        return trashes.sorted(by: Slot.order).map { .trash(view: $0.view, assetKey: $0.assetKey) }
            + moves.sorted { Slot.order($0.0, $1.0) }.map { .move(view: $0.0.view, assetKey: $0.0.assetKey, toParentLogical: $0.1) }
            + creates.sorted { Slot.order(Slot(view: $0.view, assetKey: $0.assetKey), Slot(view: $1.view, assetKey: $1.assetKey)) }
                .map { .create($0) }
    }

    private struct Slot: Hashable {
        var view: ViewKind
        var assetKey: AssetKey
        static func order(_ a: Slot, _ b: Slot) -> Bool {
            (a.view.rawValue, a.assetKey) < (b.view.rawValue, b.assetKey)
        }
    }
}
