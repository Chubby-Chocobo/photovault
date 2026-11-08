import Foundation
import GRDB
import PhotoVaultCore

/// The write a path-addressed destination (local folder, NAS) is about to make for a job: the
/// final relative path and the SHA-256 of the content. Saved in the same transaction that moves the
/// job to `uploading`, deleted in the transaction that completes it. Without it a crash between
/// the write and the completion leaves a file nobody can attribute (a day folder may have been
/// promoted, or the asset edited again, before the retry).
public struct UploadIntent: Sendable, Equatable {
    public var jobId: Int64
    public var destinationId: DestinationID
    public var remotePath: String
    public var contentSha256: String
    public var createdAt: Date

    public init(jobId: Int64, destinationId: DestinationID, remotePath: String, contentSha256: String, createdAt: Date) {
        self.jobId = jobId
        self.destinationId = destinationId
        self.remotePath = remotePath
        self.contentSha256 = contentSha256
        self.createdAt = createdAt
    }
}

public enum UploadIntentRepository {
    /// Replaces the intent of the job (a retry plans again).
    public static func save(_ db: Database, _ intent: UploadIntent) throws {
        try db.execute(sql: """
            INSERT INTO upload_intent (job_id, destination_id, remote_path, content_sha256, created_at)
            VALUES (:job, :destination, :path, :hash, :at)
            ON CONFLICT(job_id) DO UPDATE SET destination_id = excluded.destination_id, remote_path = excluded.remote_path,
                content_sha256 = excluded.content_sha256, created_at = excluded.created_at
            """, arguments: [
                "job": intent.jobId, "destination": intent.destinationId.rawValue, "path": intent.remotePath,
                "hash": intent.contentSha256, "at": intent.createdAt,
            ])
    }

    public static func fetch(_ db: Database, jobId: Int64) throws -> UploadIntent? {
        try Row.fetchOne(db, sql: "SELECT * FROM upload_intent WHERE job_id = ?", arguments: [jobId]).map(decode)
    }

    public static func delete(_ db: Database, jobId: Int64) throws {
        try db.execute(sql: "DELETE FROM upload_intent WHERE job_id = ?", arguments: [jobId])
    }

    static func decode(_ row: Row) throws -> UploadIntent {
        let table = "upload_intent"
        return UploadIntent(
            jobId: try row.require("job_id", table: table),
            destinationId: try row.destinationId("destination_id", table: table),
            remotePath: try row.require("remote_path", table: table),
            contentSha256: try row.require("content_sha256", table: table),
            createdAt: try row.require("created_at", table: table))
    }
}
