import CryptoKit
import Foundation

/// Stable identity of an asset (spec 8.1): `c:<cloudId>` when a cloud identifier is known at
/// first sight, otherwise `l:<localId>`. A key never changes once assigned; identifiers found
/// later are recorded as aliases.
public struct AssetKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("c:") || rawValue.hasPrefix("l:"), rawValue.count > 2 else { return nil }
        self.rawValue = rawValue
    }

    public static func cloud(_ cloudId: String) -> AssetKey { AssetKey(unchecked: "c:" + cloudId) }
    public static func local(_ localId: String) -> AssetKey { AssetKey(unchecked: "l:" + localId) }

    private init(unchecked: String) { rawValue = unchecked }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let key = AssetKey(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid asset key"))
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var isCloud: Bool { rawValue.hasPrefix("c:") }

    /// Identifier without the prefix.
    public var identifier: String { String(rawValue.dropFirst(2)) }

    /// Lowercase hex SHA-256 of the raw key; indexed in the store for `h:` lookups.
    public var sha256Hex: String { SHA256.hash(data: Data(rawValue.utf8)).hexString }

    /// `h:` + first 32 hex characters of the SHA-256 (FR-43 fallback for long keys).
    public var hashedForm: String { "h:" + sha256Hex.prefix(32) }

    /// Value to store in a Drive `appProperties` entry: the raw key when key + value fit in
    /// 124 UTF-8 bytes, otherwise the hashed form.
    public func appPropertyValue(forKey propertyKey: String = AppPropertyKey.assetId) -> String {
        propertyKey.utf8.count + rawValue.utf8.count <= AppPropertyCodec.maxPairBytes ? rawValue : hashedForm
    }

    public var description: String { rawValue }

    public static func < (lhs: AssetKey, rhs: AssetKey) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension Digest {
    /// Lowercase hexadecimal representation.
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
