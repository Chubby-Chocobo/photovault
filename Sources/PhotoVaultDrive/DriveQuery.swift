import Foundation
import PhotoVaultCore

/// The only way to build a Drive `q` expression. Every literal is escaped (`\\` and `'`).
public struct DriveQuery: Equatable, Sendable {
    private var clauses: [String]

    private init(_ clauses: [String]) { self.clauses = clauses }

    public static let all = DriveQuery([])

    public var q: String { clauses.joined(separator: " and ") }

    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private func adding(_ clause: String) -> DriveQuery { DriveQuery(clauses + [clause]) }

    public func appProperty(_ key: String, _ value: String) -> DriveQuery {
        adding("appProperties has { key=\(Self.literal(key)) and value=\(Self.literal(value)) }")
    }

    /// Items written by this app (`pvSchema=1`).
    public var appCreated: DriveQuery { appProperty(AppPropertyKey.schema, AppPropertyCodec.schemaVersion) }

    public var notTrashed: DriveQuery { adding("trashed=false") }

    public func parent(_ id: String) -> DriveQuery { adding("\(Self.literal(id)) in parents") }

    public func name(_ name: String) -> DriveQuery { adding("name=\(Self.literal(name))") }

    public func mimeType(_ type: String) -> DriveQuery { adding("mimeType=\(Self.literal(type))") }
}
