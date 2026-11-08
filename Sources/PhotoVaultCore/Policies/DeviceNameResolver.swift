import CryptoKit
import Foundation

/// Maps camera `make|model` to a stable group id and a default display name (FR-104).
public struct DeviceNameResolver: Sendable {
    /// Normalized `MAKE|MODEL` key to display name. Entries are [VERIFY]; owners can rename groups.
    public let table: [String: String]

    public init(table: [String: String] = [:]) {
        var normalized: [String: String] = [:]
        for (key, name) in table {
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            normalized[Self.key(make: String(parts[0]), model: String(parts[1]))] = name
        }
        self.table = normalized
    }

    /// The table shipped in `Resources/device-names.json`. A missing or corrupt resource is a
    /// packaging defect; it degrades to default names instead of blocking views, and the
    /// resolver tests fail on it.
    public static let bundled: DeviceNameResolver = {
        guard let url = Bundle.module.url(forResource: "device-names", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else {
            return DeviceNameResolver()
        }
        return DeviceNameResolver(table: table)
    }()

    static let brandNames: [String: String] = [
        "SONY": "Sony", "NIKON": "Nikon", "NIKON CORPORATION": "Nikon", "CANON": "Canon", "APPLE": "Apple",
        "DJI": "DJI", "LEICA CAMERA AG": "Leica", "LEICA": "Leica", "FUJIFILM": "Fujifilm",
        "OLYMPUS CORPORATION": "Olympus", "OLYMPUS": "Olympus", "PANASONIC": "Panasonic", "SAMSUNG": "Samsung",
    ]

    /// Trim, collapse inner whitespace, uppercase.
    public static func normalize(_ value: String?) -> String {
        (value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").uppercased()
    }

    public static func key(make: String?, model: String?) -> String {
        "\(normalize(make))|\(normalize(model))"
    }

    /// First 16 hex characters of the SHA-256 of the key; deterministic across launches.
    public static func groupId(forKey key: String) -> String {
        String(SHA256.hash(data: Data(key.utf8)).hexString.prefix(16))
    }

    public func displayName(make: String?, model: String?) -> String {
        if let named = table[Self.key(make: make, model: model)] { return named }
        return Self.defaultName(make: make, model: model)
    }

    /// `<Make> <Model>` without a repeated make prefix, brand names title-cased.
    public static func defaultName(make: String?, model: String?) -> String {
        let rawMake = collapse(make), rawModel = collapse(model)
        let brand = brandNames[normalize(rawMake)] ?? rawMake
        guard !rawModel.isEmpty else { return brand }
        guard !brand.isEmpty else { return rawModel }
        var rest = rawModel
        for prefix in [rawMake, brand, rawMake.split(separator: " ").first.map(String.init) ?? ""] where !prefix.isEmpty {
            if rest.lowercased() == prefix.lowercased() { return brand }
            if rest.lowercased().hasPrefix(prefix.lowercased() + " ") {
                rest = String(rest.dropFirst(prefix.count + 1))
                break
            }
        }
        return "\(brand) \(rest)"
    }

    private static func collapse(_ value: String?) -> String {
        (value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
