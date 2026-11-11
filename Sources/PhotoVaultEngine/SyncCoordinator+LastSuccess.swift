import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

extension SyncCoordinator {
    /// "Last successful sync" (FR-61) means files reached a destination, or nothing waiting at an
    /// active destination is failing: neither its upload nor the export it waits for has a recorded
    /// error. Work the owner's own rules hold back (battery, Low Power Mode, an expensive network, the
    /// backfill rate) has no error and does not count against it. A single file deferred after
    /// repeated failures is reported on its own (deferred and skipped counts), not as a stopped sync.
    func recordSuccess(_ report: CycleReport) async throws {
        let now = env.clock.now
        try await env.store.write { db in
            if report.uploaded == 0 {
                let failing = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM upload_job j
                    JOIN destination d ON d.id = j.destination_id
                    LEFT JOIN resource r ON r.asset_key = j.asset_key AND r.res_type = j.res_type
                    WHERE j.state IN ('pending', 'uploading') AND d.status = 'active'
                      AND (j.last_error IS NOT NULL OR (r.last_error IS NOT NULL AND NOT EXISTS (
                            SELECT 1 FROM asset a JOIN source s ON s.id = a.source_id
                            WHERE a.asset_key = j.asset_key AND s.status = 'offline')))
                    """) ?? 0
                guard failing == 0 else { return }
            }
            try KeyValueRepository.set(db, KeyValueRepository.Key.lastSuccessfulSyncAt, now)
        }
    }
}
