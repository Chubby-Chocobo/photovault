import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

extension EngineQueries {
    /// Pushes the waiting exports of one source back to `retryAt`, so a source that cannot be read
    /// is asked once and not once per file.
    static func deferExports(_ db: Database, sourceId: SourceID, until retryAt: Date) throws {
        try db.execute(sql: """
            UPDATE resource SET next_export_attempt_at = ?
            WHERE staging_state = 'none' AND (next_export_attempt_at IS NULL OR next_export_attempt_at < ?)
              AND asset_key IN (SELECT asset_key FROM asset WHERE source_id = ?)
            """, arguments: [retryAt, retryAt, sourceId.rawValue])
    }

    /// Lets the waiting exports of one source run on the next cycle (the owner signed in again).
    static func releaseExports(_ db: Database, sourceId: SourceID) throws {
        try db.execute(sql: """
            UPDATE resource SET next_export_attempt_at = NULL
            WHERE staging_state = 'none' AND next_export_attempt_at IS NOT NULL
              AND asset_key IN (SELECT asset_key FROM asset WHERE source_id = ?)
            """, arguments: [sourceId.rawValue])
    }
}
