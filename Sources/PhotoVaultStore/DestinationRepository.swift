import Foundation
import GRDB
import PhotoVaultCore

/// `destination` rows plus the add / remove / reset operations (FR-71, FR-08).
public enum DestinationRepository {
    public static func fetch(_ db: Database, id: DestinationID) throws -> DestinationRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM destination WHERE id = ?", arguments: [id.rawValue]).map(decode)
    }

    public static func fetchAll(_ db: Database) throws -> [DestinationRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM destination ORDER BY created_at, id").map(decode)
    }

    /// FR-71: a new destination gets its own scope and `baseline_at = now`.
    public static func add(_ db: Database, _ destination: DestinationRecord, now: Date) throws -> DestinationRecord {
        var record = destination
        record.baselineAt = now
        record.statusSince = now
        record.createdAt = now
        try save(db, record)
        return record
    }

    /// Insert or full update.
    public static func save(_ db: Database, _ d: DestinationRecord) throws {
        try db.execute(sql: """
        INSERT INTO destination (
            id, kind, display_name, status, status_reason, status_since, scope_mode, scope_since, baseline_at,
            rules_json, config_json, account_id, account_email, recovery_required, last_success_at, created_at)
        VALUES (
            :id, :kind, :display_name, :status, :status_reason, :status_since, :scope_mode, :scope_since,
            :baseline_at, :rules_json, :config_json, :account_id, :account_email, :recovery_required,
            :last_success_at, :created_at)
        ON CONFLICT(id) DO UPDATE SET
            display_name = excluded.display_name, status = excluded.status, status_reason = excluded.status_reason,
            status_since = excluded.status_since, scope_mode = excluded.scope_mode,
            scope_since = excluded.scope_since, baseline_at = excluded.baseline_at,
            rules_json = excluded.rules_json, config_json = excluded.config_json,
            account_id = excluded.account_id, account_email = excluded.account_email,
            recovery_required = excluded.recovery_required, last_success_at = excluded.last_success_at
        """, arguments: [
            "id": d.id.rawValue, "kind": d.kind.rawValue, "display_name": d.displayName,
            "status": d.status.storageName, "status_reason": d.status.reason?.rawValue,
            "status_since": d.statusSince, "scope_mode": d.scope.storageName,
            "scope_since": d.scope.sinceDay?.description, "baseline_at": d.baselineAt,
            "rules_json": try Json.encode(d.rules), "config_json": try Json.encode(d.config),
            "account_id": d.accountId, "account_email": d.accountEmail,
            "recovery_required": d.recoveryRequired, "last_success_at": d.lastSuccessAt,
            "created_at": d.createdAt,
        ])
    }

    /// Changes the status; `status_since` moves only when the status actually changes (FR-61).
    public static func setStatus(_ db: Database, id: DestinationID, status: DestinationStatus, now: Date) throws {
        guard let current = try fetch(db, id: id) else { throw StoreError.notFound("destination \(id)") }
        guard current.status != status else { return }
        try db.execute(
            sql: "UPDATE destination SET status = ?, status_reason = ?, status_since = ? WHERE id = ?",
            arguments: [status.storageName, status.reason?.rawValue, now, id.rawValue])
    }

    public static func setRecoveryRequired(_ db: Database, id: DestinationID, _ required: Bool) throws {
        try db.execute(
            sql: "UPDATE destination SET recovery_required = ? WHERE id = ?", arguments: [required, id.rawValue])
    }

    public static func markSuccess(_ db: Database, id: DestinationID, at date: Date) throws {
        try db.execute(sql: "UPDATE destination SET last_success_at = ? WHERE id = ?", arguments: [date, id.rawValue])
    }

    static func markAllRecoveryRequired(_ db: Database) throws {
        try db.execute(sql: "UPDATE destination SET recovery_required = 1")
    }

    /// FR-71: removes this destination's DB state only; nothing at the destination is touched.
    /// Asset, resource and name data are shared and stay.
    public static func remove(_ db: Database, id: DestinationID) throws {
        try deleteDependents(db, id: id)
        try db.execute(sql: "DELETE FROM destination WHERE id = ?", arguments: [id.rawValue])
    }

    /// FR-08: the Drive root or account changed. Drops everything learned about the old location
    /// (jobs, folders, moves, shortcuts) and requires recovery (FR-51) before uploads resume;
    /// eligibility recreates the jobs.
    public static func resetState(_ db: Database, id: DestinationID) throws {
        try deleteDependents(db, id: id)
        try setRecoveryRequired(db, id: id, true)
    }

    private static func deleteDependents(_ db: Database, id: DestinationID) throws {
        for table in ["upload_job", "remote_folder", "move_job", "shortcut"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE destination_id = ?", arguments: [id.rawValue])
        }
    }

    static func decode(_ row: Row) throws -> DestinationRecord {
        let table = "destination"
        let reason: StatusReason? = try row.optionalEnum("status_reason", table: table)
        let statusName: String = try row.require("status", table: table)
        guard let status = DestinationStatus(storageName: statusName, reason: reason) else {
            throw StoreError.corruptRow(table: table, column: "status")
        }
        let sinceDay: ArchiveDay? = try row.optionalParse("scope_since", table: table) { (raw: String) in ArchiveDay(string: raw) }
        let scopeName: String = try row.require("scope_mode", table: table)
        guard let scope = ScopeMode(storageName: scopeName, since: sinceDay) else {
            throw StoreError.corruptRow(table: table, column: "scope_mode")
        }
        var record = DestinationRecord(
            id: try row.destinationId("id", table: table),
            displayName: try row.require("display_name", table: table),
            status: status,
            statusSince: try row.require("status_since", table: table),
            scope: scope,
            baselineAt: row["baseline_at"],
            rules: try Json.decode(DestinationRules.self, from: row.require("rules_json", table: table), table: table, column: "rules_json"),
            config: try Json.decode(DestinationConfig.self, from: row.require("config_json", table: table), table: table, column: "config_json"),
            accountId: row["account_id"],
            accountEmail: row["account_email"],
            recoveryRequired: row["recovery_required"],
            lastSuccessAt: row["last_success_at"],
            createdAt: try row.require("created_at", table: table))
        record.kind = try row.enumValue("kind", table: table)
        return record
    }
}
