import Foundation
import GRDB
import PhotoVaultCore

/// `source` rows: one-time import jobs and, later, continuous sources.
public enum SourceRepository {
    public static func insert(_ db: Database, _ source: SourceRecord) throws {
        try db.execute(sql: """
        INSERT INTO source (id, kind, mode, display_name, config_json, status, status_reason, created_at, listed_at, finished_at)
        VALUES (:id, :kind, :mode, :display_name, :config_json, :status, :status_reason, :created_at, :listed_at, :finished_at)
        """, arguments: [
            "id": source.id.rawValue, "kind": source.kind.rawValue, "mode": source.mode.rawValue,
            "display_name": source.displayName, "config_json": try Json.encode(source.config),
            "status": source.status.rawValue, "status_reason": source.statusReason, "created_at": source.createdAt,
            "listed_at": source.listedAt, "finished_at": source.finishedAt,
        ])
    }

    public static func fetch(_ db: Database, id: SourceID) throws -> SourceRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM source WHERE id = ?", arguments: [id.rawValue]).map(decode)
    }

    /// Oldest first.
    public static func fetchAll(_ db: Database) throws -> [SourceRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM source ORDER BY created_at, id").map(decode)
    }

    /// `finished_at` is set when the job reaches `completed` or `cancelled`, and cleared otherwise.
    public static func setStatus(_ db: Database, id: SourceID, status: SourceStatus, reason: String?, now: Date) throws {
        let finished: Date? = status.isOpen ? nil : now
        try db.execute(
            sql: "UPDATE source SET status = ?, status_reason = ?, finished_at = ? WHERE id = ?",
            arguments: [status.rawValue, reason, finished, id.rawValue])
    }

    public static func setListed(_ db: Database, id: SourceID, now: Date) throws {
        try db.execute(sql: "UPDATE source SET listed_at = ? WHERE id = ?", arguments: [now, id.rawValue])
    }

    public static func setConfig(_ db: Database, id: SourceID, _ config: SourceConfig) throws {
        try db.execute(sql: "UPDATE source SET config_json = ? WHERE id = ?", arguments: [try Json.encode(config), id.rawValue])
    }

    static func decode(_ row: Row) throws -> SourceRecord {
        let table = "source"
        return SourceRecord(
            id: try row.parse("id", table: table) { (raw: String) in SourceID(rawValue: raw) },
            kind: try row.enumValue("kind", table: table),
            mode: try row.enumValue("mode", table: table),
            displayName: try row.require("display_name", table: table),
            config: try Json.decode(SourceConfig.self, from: row.require("config_json", table: table), table: table, column: "config_json"),
            status: try row.enumValue("status", table: table),
            statusReason: row["status_reason"],
            createdAt: try row.require("created_at", table: table),
            listedAt: row["listed_at"],
            finishedAt: row["finished_at"])
    }
}
