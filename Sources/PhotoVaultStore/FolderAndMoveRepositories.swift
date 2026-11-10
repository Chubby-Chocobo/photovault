import Foundation
import GRDB
import PhotoVaultCore

/// `remote_folder`.
public enum RemoteFolderRepository {
    public static func fetch(_ db: Database, destinationId: DestinationID, logicalPath: String) throws -> RemoteFolder? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM remote_folder WHERE destination_id = ? AND logical_path = ?",
            arguments: [destinationId.rawValue, logicalPath]).map(decode)
    }

    public static func fetchAll(_ db: Database, destinationId: DestinationID) throws -> [RemoteFolder] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM remote_folder WHERE destination_id = ? ORDER BY logical_path",
            arguments: [destinationId.rawValue]).map(decode)
    }

    public static func save(_ db: Database, _ folder: RemoteFolder) throws {
        try db.execute(sql: """
            INSERT INTO remote_folder (destination_id, logical_path, remote_id, display_name, created, verified_session)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(destination_id, logical_path) DO UPDATE SET
                remote_id = excluded.remote_id, display_name = excluded.display_name,
                created = excluded.created, verified_session = excluded.verified_session
            """, arguments: [
                folder.destinationId.rawValue, folder.logicalPath, folder.remoteId, folder.displayName,
                folder.created, folder.verifiedSession,
            ])
    }

    static func decode(_ row: Row) throws -> RemoteFolder {
        RemoteFolder(
            destinationId: try row.destinationId("destination_id", table: "remote_folder"),
            logicalPath: try row.require("logical_path", table: "remote_folder"),
            remoteId: row["remote_id"],
            displayName: try row.require("display_name", table: "remote_folder"),
            created: row["created"],
            verifiedSession: row["verified_session"])
    }
}

/// `move_job`: pending → inProgress → done; more than 8 failures → failed.
public enum MoveJobRepository {
    @discardableResult
    public static func insert(_ db: Database, _ job: MoveJob) throws -> MoveJob {
        try db.execute(sql: """
            INSERT INTO move_job (destination_id, op, subject, from_value, to_value, state, attempts, last_error, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                job.destinationId.rawValue, job.operation.rawValue, job.subject, job.fromValue, job.toValue,
                job.state.rawValue, job.attempts, job.lastError, job.createdAt,
            ])
        var saved = job
        saved.id = db.lastInsertedRowID
        return saved
    }

    public static func fetch(_ db: Database, id: Int64) throws -> MoveJob? {
        try Row.fetchOne(db, sql: "SELECT * FROM move_job WHERE id = ?", arguments: [id]).map(decode)
    }

    /// The oldest `limit` jobs (all of them when nil). A file move that has failed before comes after the
    /// ones that have not, so a few stubborn moves cannot hold back the rest of a capped pass; renames keep
    /// their queue order.
    public static func fetch(_ db: Database, destinationId: DestinationID, state: MoveJobState, limit: Int? = nil) throws -> [MoveJob] {
        try Row.fetchAll(
            db, sql: """
                SELECT * FROM move_job WHERE destination_id = ? AND state = ?
                ORDER BY CASE WHEN op = 'moveFile' THEN attempts ELSE 0 END, id LIMIT ?
                """,
            arguments: [destinationId.rawValue, state.rawValue, limit ?? -1]).map(decode)
    }

    /// `pending → inProgress`.
    @discardableResult
    public static func start(_ db: Database, id: Int64) throws -> Bool {
        try db.execute(sql: "UPDATE move_job SET state = 'inProgress' WHERE id = ? AND state = 'pending'", arguments: [id])
        return db.changesCount > 0
    }

    /// `inProgress → done`.
    @discardableResult
    public static func complete(_ db: Database, id: Int64) throws -> Bool {
        try db.execute(
            sql: "UPDATE move_job SET state = 'done', last_error = NULL WHERE id = ? AND state = 'inProgress'",
            arguments: [id])
        return db.changesCount > 0
    }

    /// `inProgress → pending`, or `failed` once attempts exceed the limit. Returns the new state.
    @discardableResult
    public static func fail(_ db: Database, id: Int64, message: String) throws -> MoveJobState? {
        guard let job = try fetch(db, id: id), job.state == .inProgress else { return nil }
        let attempts = job.attempts + 1
        let state: MoveJobState = attempts > MoveJob.maxAttempts ? .failed : .pending
        try db.execute(
            sql: "UPDATE move_job SET state = ?, attempts = ?, last_error = ? WHERE id = ?",
            arguments: [state.rawValue, attempts, message, id])
        return state
    }

    /// Startup: failed file moves `failed → pending` with a fresh attempt count. A move that no longer applies
    /// (the file already sits in its slot's folder) is discarded when it runs; the others get another try.
    /// Folder renames stay failed: a later rename queued from the name on disk would be overtaken by the old one.
    @discardableResult
    public static func rearmFailedOnStartup(_ db: Database) throws -> Int {
        try db.execute(sql: "UPDATE move_job SET state = 'pending', attempts = 0 WHERE state = 'failed' AND op = 'moveFile'")
        return db.changesCount
    }

    /// Startup recovery: interrupted moves become pending again.
    @discardableResult
    public static func resetInProgressOnStartup(_ db: Database) throws -> Int {
        try db.execute(sql: "UPDATE move_job SET state = 'pending' WHERE state = 'inProgress'")
        return db.changesCount
    }

    static func decode(_ row: Row) throws -> MoveJob {
        let table = "move_job"
        return MoveJob(
            id: row["id"],
            destinationId: try row.destinationId("destination_id", table: table),
            operation: try row.enumValue("op", table: table),
            subject: try row.require("subject", table: table),
            fromValue: try row.require("from_value", table: table),
            toValue: try row.require("to_value", table: table),
            state: try row.enumValue("state", table: table),
            attempts: row["attempts"],
            lastError: row["last_error"],
            createdAt: try row.require("created_at", table: table))
    }
}
