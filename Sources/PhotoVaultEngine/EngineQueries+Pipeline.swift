import Foundation
import GRDB
import PhotoVaultCore

/// What the overlapped cycle round looks at to keep its look-ahead bounded and new photos first.
extension EngineQueries {
    /// Resources waiting for an export now, with the conditions `exportCandidates` uses: not staged, placed, due, and needed
    /// by a pending job at an active destination.
    private static let waitingForExport = """
        r.staging_state = 'none' AND r.too_large_for_disk = 0
          AND a.placement_category IS NOT NULL AND a.deleted_at IS NULL
          AND (r.next_export_attempt_at IS NULL OR r.next_export_attempt_at <= :now)
          AND EXISTS (SELECT 1 FROM upload_job j JOIN destination d ON d.id = j.destination_id
                      WHERE j.asset_key = r.asset_key AND j.res_type = r.res_type AND j.state = 'pending'
                        AND j.target_gen <= r.content_gen AND d.status = 'active' AND d.recovery_required = 0
                        AND (:incrementalOnly = 0 OR j.origin = 'incremental'))
        """

    /// Bytes of an import's files that were read and recorded but are not staged yet: how far its reads are ahead of its exports.
    static func importExportBacklogBytes(_ db: Database, sourceId: SourceID, now: Date) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(r.size_bytes), 0) FROM resource r JOIN asset a ON a.asset_key = r.asset_key
            WHERE a.source_id = :source AND \(waitingForExport)
            """, arguments: ["source": sourceId.rawValue, "now": now, "incrementalOnly": false]) ?? 0
    }

    /// True while a new Photos asset waits for its export.
    static func photosExportWaiting(_ db: Database, now: Date) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM resource r JOIN asset a ON a.asset_key = r.asset_key
                           WHERE a.source_id = :source AND \(waitingForExport))
            """, arguments: ["source": SourceID.photos.rawValue, "now": now, "incrementalOnly": true]) ?? false
    }
}
