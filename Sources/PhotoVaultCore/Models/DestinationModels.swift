import Foundation

/// `gdrive` or `local-<uuid>` (spec 8.2).
public struct DestinationID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        if rawValue == "gdrive" {
            self.rawValue = rawValue
        } else if rawValue.hasPrefix("local-"), UUID(uuidString: String(rawValue.dropFirst(6))) != nil {
            self.rawValue = rawValue
        } else {
            return nil
        }
    }

    public static let googleDrive = DestinationID(rawValue: "gdrive")!

    public static func local(_ uuid: UUID = UUID()) -> DestinationID {
        DestinationID(rawValue: "local-" + uuid.uuidString)!
    }

    public var kind: DestinationKind { rawValue == "gdrive" ? .googleDrive : .localFolder }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let id = DestinationID(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid destination id"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
    public static func < (lhs: DestinationID, rhs: DestinationID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum DestinationKind: String, Codable, Sendable, CaseIterable {
    case googleDrive
    case localFolder
}

/// Reason attached to a non-active destination status (spec 8.9.2).
public enum StatusReason: String, Codable, Sendable, CaseIterable {
    case userPaused, full, dailyCapReached, offline, bookmarkInvalid, reauthRequired, signedOut
    case rootMissing, rootTrashed, folderTrashed, recovering, waitingForDrive
}

/// Destination status (spec 8.9.2).
public enum DestinationStatus: Hashable, Codable, Sendable, CustomStringConvertible {
    case active
    case paused(StatusReason)
    case unavailable(StatusReason)
    case error(StatusReason)

    public var isActive: Bool { self == .active }

    public var reason: StatusReason? {
        switch self {
        case .active: nil
        case .paused(let r), .unavailable(let r), .error(let r): r
        }
    }

    public var storageName: String {
        switch self {
        case .active: "active"
        case .paused: "paused"
        case .unavailable: "unavailable"
        case .error: "error"
        }
    }

    public init?(storageName: String, reason: StatusReason?) {
        switch (storageName, reason) {
        case ("active", _): self = .active
        case ("paused", let r?): self = .paused(r)
        case ("unavailable", let r?): self = .unavailable(r)
        case ("error", let r?): self = .error(r)
        default: return nil
        }
    }

    public var description: String {
        reason.map { "\(storageName)(\($0.rawValue))" } ?? storageName
    }
}
