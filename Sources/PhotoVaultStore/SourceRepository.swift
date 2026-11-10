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

    /// Imports that may need an adapter when the app starts: Mac folders with a bookmark and every cloud
    /// import, finished or not (a finished import's files may still be read for a destination added later).
    /// The app drops cloud rows whose stored grant is gone.
    public static func readableImports(_ db: Database) throws -> [SourceRecord] {
        try fetchAll(db).filter { $0.kind.isImport && ($0.kind != .localFolder || $0.config.bookmark != nil) }
    }

    /// `finished_at` is set when the job reaches `completed` or `cancelled`, and cleared otherwise.
    public static func setStatus(_ db: Database, id: SourceID, status: SourceStatus, reason: String?, now: Date) throws {
        let finished: Date? = status.isOpen ? nil : now
        try db.execute(
            sql: "UPDATE source SET status = ?, status_reason = ?, finished_at = ? WHERE id = ?",
            arguments: [status.rawValue, reason, finished, id.rawValue])
    }

    /// Changes only the machine reason of a row, for example "needs sign-in" on a finished import.
    public static func setStatusReason(_ db: Database, id: SourceID, reason: String?) throws {
        try db.execute(sql: "UPDATE source SET status_reason = ? WHERE id = ?", arguments: [reason, id.rawValue])
    }

    public static func setListed(_ db: Database, id: SourceID, now: Date) throws {
        try db.execute(sql: "UPDATE source SET listed_at = ? WHERE id = ?", arguments: [now, id.rawValue])
    }

    /// Stores a re-created security-scoped bookmark and keeps the rest of the stored config. A missing row is left alone.
    public static func setBookmark(_ db: Database, id: SourceID, _ bookmark: Data) throws {
        guard var config = try fetch(db, id: id)?.config else { return }
        config.bookmark = bookmark
        try setConfig(db, id: id, config)
    }

    /// Changes the stored config in one transaction, so a field written meanwhile (a stored cancel) is kept. A missing row is left alone.
    public static func updateConfig(_ db: Database, id: SourceID, _ change: (inout SourceConfig) -> Void) throws {
        guard var config = try fetch(db, id: id)?.config else { return }
        change(&config)
        try setConfig(db, id: id, config)
    }

    /// Records that the owner asked to cancel `id`, keeping the rest of the stored config. A missing or finished row is left alone.
    public static func requestCancel(_ db: Database, id: SourceID) throws {
        guard var row = try fetch(db, id: id), row.status.isOpen, row.config.cancelRequested != true else { return }
        row.config.cancelRequested = true
        try setConfig(db, id: id, row.config)
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
