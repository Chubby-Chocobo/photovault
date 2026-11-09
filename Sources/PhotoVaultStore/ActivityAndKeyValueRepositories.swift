import Foundation
import GRDB
import PhotoVaultCore

/// `activity`: newest 500 events (FR-63). Events carry no secrets (`session_ref` never appears).
public enum ActivityRepository {
    public static func record(_ db: Database, _ event: ActivityEvent) throws {
        try db.execute(sql: """
            INSERT INTO activity (at, kind, destination_id, asset_key, message) VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                event.at, event.kind.rawValue, event.destinationId?.rawValue, event.assetKey?.rawValue, event.message,
            ])
        try db.execute(
            sql: "DELETE FROM activity WHERE id <= (SELECT MAX(id) FROM activity) - ?",
            arguments: [ActivityEvent.retainedCount])
    }

    /// Newest first.
    public static func recent(_ db: Database, limit: Int = ActivityEvent.retainedCount) throws -> [ActivityEvent] {
        try Row.fetchAll(db, sql: "SELECT * FROM activity ORDER BY id DESC LIMIT ?", arguments: [limit]).map { row in
            ActivityEvent(
                id: row["id"],
                at: try row.require("at", table: "activity"),
                kind: try row.enumValue("kind", table: "activity"),
                destinationId: try row.optionalParse("destination_id", table: "activity") { (raw: String) in DestinationID(rawValue: raw) },
                assetKey: try row.optionalParse("asset_key", table: "activity") { (raw: String) in AssetKey(rawValue: raw) },
                message: try row.require("message", table: "activity"))
        }
    }
}

/// `kv`: baseline/change tokens, scan state and cursor, archive timezone, schema version and the
/// since-timestamps behind FR-61 duration notifications.
public enum KeyValueRepository {
    public enum Key {
        public static let baselineToken = "baseline_token"
        public static let changeToken = "change_token"
        public static let scanState = "scan_state"
        public static let scanCursor = "scan_cursor"
        public static let archiveTimezone = "archive_timezone"
        public static let schemaVersion = "schema_version"
        public static let macDiskFullSince = "mac_disk_full_since"
        public static let lastSuccessfulSyncAt = "last_successful_sync_at"
        /// "1" when the database holds a backup in the old `YYYY/MM` folder layout, "0" when it does not.
        public static let legacyLayout = "legacy_layout"
    }

    public static func string(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
    }

    public static func data(_ db: Database, _ key: String) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
    }

    public static func date(_ db: Database, _ key: String) throws -> Date? {
        try Date.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
    }

    public static func int(_ db: Database, _ key: String) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
    }

    /// Stores `value`, or deletes the key when nil.
    public static func set(_ db: Database, _ key: String, _ value: (any DatabaseValueConvertible)?) throws {
        guard let value else {
            try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
            return
        }
        try db.execute(sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", arguments: [key, value])
    }

    // MARK: Typed accessors

    public static func scanState(_ db: Database) throws -> ScanState {
        try string(db, Key.scanState).flatMap(ScanState.init(rawValue:)) ?? .notStarted
    }

    public static func setScanState(_ db: Database, _ state: ScanState) throws {
        try set(db, Key.scanState, state.rawValue)
    }

    public static func archiveTimeZone(_ db: Database) throws -> TimeZone? {
        try string(db, Key.archiveTimezone).flatMap { TimeZone(identifier: $0) }
    }

    public static func setArchiveTimeZone(_ db: Database, _ zone: TimeZone) throws {
        try set(db, Key.archiveTimezone, zone.identifier)
    }

    /// Sets the timestamp only when none is stored, so the "since" moment of an ongoing condition
    /// is not reset by repeated observations.
    public static func markSinceIfAbsent(_ db: Database, _ key: String, at date: Date) throws {
        if try self.date(db, key) == nil { try set(db, key, date) }
    }
}
