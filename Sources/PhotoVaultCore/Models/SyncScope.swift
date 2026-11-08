import Foundation

/// Sync mode of a destination (FR-06, spec 8.8).
public enum ScopeMode: Hashable, Codable, Sendable {
    case full
    case since(ArchiveDay)
    case newOnly

    public var storageName: String {
        switch self {
        case .full: "full"
        case .since: "since"
        case .newOnly: "newOnly"
        }
    }

    public var sinceDay: ArchiveDay? {
        if case .since(let d) = self { return d }
        return nil
    }

    public init?(storageName: String, since: ArchiveDay?) {
        switch storageName {
        case "full": self = .full
        case "newOnly": self = .newOnly
        case "since":
            guard let since else { return nil }
            self = .since(since)
        default: return nil
        }
    }
}
