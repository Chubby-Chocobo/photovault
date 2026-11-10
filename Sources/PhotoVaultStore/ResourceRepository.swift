import Foundation
import GRDB
import PhotoVaultCore

/// `resource` rows and the staging state machine `none → exporting → ready → none` (spec 8.3).
public enum ResourceRepository {
    /// Inserts a new resource or refreshes its descriptor fields, leaving staging and counters alone.
    /// `contentGen` only moves forward.
    public static func upsert(_ db: Database, _ resource: ResourceRecord) throws {
        try db.execute(sql: """
        INSERT INTO resource (
            asset_key, res_type, kind, is_raw, original_filename, uti, size_bytes, content_gen, md5, sha256,
            staging_gen, staging_path, staging_state, export_count, export_attempts, export_deferred_since,
            next_export_attempt_at, bytes_received_at_cancel, disk_cancel_count, too_large_for_disk,
            last_used_at, last_error)
        VALUES (
            :asset_key, :res_type, :kind, :is_raw, :original_filename, :uti, :size_bytes, :content_gen, :md5,
            :sha256, :staging_gen, :staging_path, :staging_state, :export_count, :export_attempts,
            :export_deferred_since, :next_export_attempt_at, :bytes_received_at_cancel, :disk_cancel_count,
            :too_large_for_disk, :last_used_at, :last_error)
        ON CONFLICT(asset_key, res_type) DO UPDATE SET
            kind = excluded.kind, is_raw = excluded.is_raw, original_filename = excluded.original_filename,
            uti = excluded.uti, size_bytes = COALESCE(excluded.size_bytes, resource.size_bytes),
            content_gen = MAX(resource.content_gen, excluded.content_gen)
        """, arguments: [
            "asset_key": resource.assetKey.rawValue, "res_type": resource.type.rawValue,
            "kind": resource.kind.rawValue, "is_raw": resource.isRaw,
            "original_filename": resource.originalFilename, "uti": resource.uti,
            "size_bytes": resource.sizeBytes, "content_gen": resource.contentGen, "md5": resource.md5,
            "sha256": resource.sha256, "staging_gen": resource.stagingGen, "staging_path": resource.stagingPath,
            "staging_state": resource.stagingState.rawValue, "export_count": resource.exportCount,
            "export_attempts": resource.exportAttempts, "export_deferred_since": resource.exportDeferredSince,
            "next_export_attempt_at": resource.nextExportAttemptAt,
            "bytes_received_at_cancel": resource.bytesReceivedAtCancel,
            "disk_cancel_count": resource.diskCancelCount, "too_large_for_disk": resource.tooLargeForDisk,
            "last_used_at": resource.lastUsedAt, "last_error": resource.lastError,
        ])
    }

    public static func fetch(_ db: Database, key: AssetKey, type: ResourceType) throws -> ResourceRecord? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM resource WHERE asset_key = ? AND res_type = ?",
            arguments: [key.rawValue, type.rawValue]).map(decode)
    }

    public static func fetchAll(_ db: Database, key: AssetKey) throws -> [ResourceRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM resource WHERE asset_key = ? ORDER BY res_type", arguments: [key.rawValue])
            .map(decode)
    }

    /// Resources in `state`, oldest `last_used_at` first (idle staging release).
    public static func fetch(_ db: Database, stagingState: StagingState, limit: Int = 1000) throws -> [ResourceRecord] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM resource WHERE staging_state = ? ORDER BY last_used_at LIMIT ?",
            arguments: [stagingState.rawValue, limit]).map(decode)
    }

    // MARK: Staging transitions

    /// `none → exporting`. Returns false when the resource is not in `none`.
    @discardableResult
    public static func beginExport(_ db: Database, key: AssetKey, type: ResourceType, generation: Int) throws -> Bool {
        try db.execute(sql: """
            UPDATE resource SET staging_state = 'exporting', staging_gen = ?
            WHERE asset_key = ? AND res_type = ? AND staging_state = 'none'
            """, arguments: [generation, key.rawValue, type.rawValue])
        return db.changesCount > 0
    }

    /// `exporting → ready`: records the file, its hashes, and resets the failure counters.
    @discardableResult
    public static func completeExport(
        _ db: Database, key: AssetKey, type: ResourceType, path: String, sizeBytes: Int64,
        md5: String?, sha256: String?, now: Date
    ) throws -> Bool {
        try db.execute(sql: """
            UPDATE resource SET staging_state = 'ready', staging_path = ?, size_bytes = ?, md5 = ?, sha256 = ?,
                export_count = export_count + 1, export_attempts = 0, export_deferred_since = NULL,
                next_export_attempt_at = NULL, bytes_received_at_cancel = NULL, last_error = NULL, last_used_at = ?
            WHERE asset_key = ? AND res_type = ? AND staging_state = 'exporting'
            """, arguments: [path, sizeBytes, md5, sha256, now, key.rawValue, type.rawValue])
        return db.changesCount > 0
    }

    /// `exporting → none` after a failure: bumps the single export-error counter (FR-23) and sets
    /// Records why a transient export failed (iCloud not delivering, a stalled download) without
    /// counting an attempt, so a failure that lasts for days is still visible. Cleared on success.
    public static func noteExportError(_ db: Database, key: AssetKey, type: ResourceType, message: String) throws {
        try db.execute(sql: "UPDATE resource SET last_error = ? WHERE asset_key = ? AND res_type = ?",
                       arguments: [message, key.rawValue, type.rawValue])
    }

    /// Forgets a recorded export error, for a file whose source is only waiting.
    public static func clearExportError(_ db: Database, key: AssetKey, type: ResourceType) throws {
        try db.execute(sql: "UPDATE resource SET last_error = NULL WHERE asset_key = ? AND res_type = ?",
                       arguments: [key.rawValue, type.rawValue])
    }

    /// the backoff. Returns the new attempt count, or nil when the resource was not exporting.
    @discardableResult
    public static func failExport(
        _ db: Database, key: AssetKey, type: ResourceType, message: String, retryAt: Date, now: Date
    ) throws -> Int? {
        try db.execute(sql: """
            UPDATE resource SET staging_state = 'none', export_attempts = export_attempts + 1,
                last_error = ?, next_export_attempt_at = ?,
                export_deferred_since = COALESCE(export_deferred_since, ?)
            WHERE asset_key = ? AND res_type = ? AND staging_state = 'exporting'
            """, arguments: [message, retryAt, now, key.rawValue, type.rawValue])
        guard db.changesCount > 0 else { return nil }
        return try Int.fetchOne(
            db, sql: "SELECT export_attempts FROM resource WHERE asset_key = ? AND res_type = ?",
            arguments: [key.rawValue, type.rawValue])
    }

    /// `exporting → none` after the disk guard cancelled the export (FR-31). A resource that is
    /// now too large for the disk is retried at `retryAt` at the latest (`next_export_attempt_at`),
    /// or earlier when the free space grows past the bytes it reached.
    @discardableResult
    public static func cancelExportForDisk(
        _ db: Database, key: AssetKey, type: ResourceType, bytesReceived: Int64?, tooLarge: Bool, retryAt: Date? = nil
    ) throws -> Bool {
        try db.execute(sql: """
            UPDATE resource SET staging_state = 'none', bytes_received_at_cancel = ?,
                disk_cancel_count = disk_cancel_count + 1, too_large_for_disk = ?,
                next_export_attempt_at = CASE WHEN ? THEN ? ELSE next_export_attempt_at END
            WHERE asset_key = ? AND res_type = ? AND staging_state = 'exporting'
            """, arguments: [bytesReceived, tooLarge, tooLarge, retryAt, key.rawValue, type.rawValue])
        return db.changesCount > 0
    }

    /// `ready → none` when staging is released.
    @discardableResult
    public static func releaseStaging(_ db: Database, key: AssetKey, type: ResourceType) throws -> Bool {
        try db.execute(sql: """
            UPDATE resource SET staging_state = 'none', staging_path = NULL
            WHERE asset_key = ? AND res_type = ? AND staging_state = 'ready'
            """, arguments: [key.rawValue, type.rawValue])
        return db.changesCount > 0
    }

    public static func touch(_ db: Database, key: AssetKey, type: ResourceType, now: Date) throws {
        try db.execute(
            sql: "UPDATE resource SET last_used_at = ? WHERE asset_key = ? AND res_type = ?",
            arguments: [now, key.rawValue, type.rawValue])
    }

    /// Raises `content_gen` (an edit changed the content, FR-46). Never lowers it.
    public static func bumpContentGen(_ db: Database, key: AssetKey, type: ResourceType) throws -> Int? {
        try db.execute(
            sql: "UPDATE resource SET content_gen = content_gen + 1 WHERE asset_key = ? AND res_type = ?",
            arguments: [key.rawValue, type.rawValue])
        return try Int.fetchOne(
            db, sql: "SELECT content_gen FROM resource WHERE asset_key = ? AND res_type = ?",
            arguments: [key.rawValue, type.rawValue])
    }

    /// Startup recovery: resources left `exporting` return to `none`. Returns how many changed.
    @discardableResult
    public static func resetExportingOnStartup(_ db: Database) throws -> Int {
        try db.execute(sql: "UPDATE resource SET staging_state = 'none' WHERE staging_state = 'exporting'")
        return db.changesCount
    }

    static func decode(_ row: Row) throws -> ResourceRecord {
        let table = "resource"
        var record = ResourceRecord(
            assetKey: try row.assetKey("asset_key", table: table),
            type: try row.parse("res_type", table: table) { (raw: Int) in ResourceType(rawValue: raw) },
            isRaw: row["is_raw"],
            originalFilename: try row.require("original_filename", table: table),
            uti: try row.require("uti", table: table),
            sizeBytes: row["size_bytes"],
            contentGen: row["content_gen"],
            md5: row["md5"],
            sha256: row["sha256"],
            stagingGen: row["staging_gen"],
            stagingPath: row["staging_path"],
            stagingState: try row.enumValue("staging_state", table: table),
            exportCount: row["export_count"],
            exportAttempts: row["export_attempts"],
            exportDeferredSince: row["export_deferred_since"],
            nextExportAttemptAt: row["next_export_attempt_at"],
            bytesReceivedAtCancel: row["bytes_received_at_cancel"],
            diskCancelCount: row["disk_cancel_count"],
            tooLargeForDisk: row["too_large_for_disk"],
            lastUsedAt: row["last_used_at"],
            lastError: row["last_error"])
        record.kind = try row.enumValue("kind", table: table)
        return record
    }
}
