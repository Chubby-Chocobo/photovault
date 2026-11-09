import Foundation
import PhotoVaultCore

/// `.photovault/destination.json` (FR-74): identifies the destination that owns a folder.
public struct DestinationMarker: Codable, Hashable, Sendable {
    public static let currentSchema = 1

    public var id: DestinationID
    public var createdAt: Date
    public var schema: Int
    public var archiveTimezone: String

    public init(id: DestinationID, createdAt: Date, schema: Int = DestinationMarker.currentSchema, archiveTimezone: String) {
        self.id = id
        self.createdAt = createdAt
        self.schema = schema
        self.archiveTimezone = archiveTimezone
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
