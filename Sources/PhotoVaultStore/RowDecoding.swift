import Foundation
import GRDB
import PhotoVaultCore

/// Decoding helpers that turn an unparsable stored value into `StoreError.corruptRow`.
extension Row {
    func require<T: DatabaseValueConvertible & StatementColumnConvertible>(_ column: String, table: String) throws -> T {
        guard let value: T = self[column] else { throw StoreError.corruptRow(table: table, column: column) }
        return value
    }

    func parse<Raw: DatabaseValueConvertible & StatementColumnConvertible, T>(
        _ column: String, table: String, _ transform: (Raw) -> T?
    ) throws -> T {
        let raw: Raw = try require(column, table: table)
        guard let value = transform(raw) else { throw StoreError.corruptRow(table: table, column: column) }
        return value
    }

    func optionalParse<Raw: DatabaseValueConvertible & StatementColumnConvertible, T>(
        _ column: String, table: String, _ transform: (Raw) -> T?
    ) throws -> T? {
        guard let raw: Raw = self[column] else { return nil }
        guard let value = transform(raw) else { throw StoreError.corruptRow(table: table, column: column) }
        return value
    }

    func enumValue<E: RawRepresentable>(_ column: String, table: String, as: E.Type = E.self) throws -> E
    where E.RawValue == String {
        try parse(column, table: table) { (raw: String) in E(rawValue: raw) }
    }

    func optionalEnum<E: RawRepresentable>(_ column: String, table: String, as: E.Type = E.self) throws -> E?
    where E.RawValue == String {
        try optionalParse(column, table: table) { (raw: String) in E(rawValue: raw) }
    }

    func assetKey(_ column: String, table: String) throws -> AssetKey {
        try parse(column, table: table) { (raw: String) in AssetKey(rawValue: raw) }
    }

    func destinationId(_ column: String, table: String) throws -> DestinationID {
        try parse(column, table: table) { (raw: String) in DestinationID(rawValue: raw) }
    }
}

enum Json {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String, table: String, column: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch {
            throw StoreError.corruptRow(table: table, column: column)
        }
    }
}
