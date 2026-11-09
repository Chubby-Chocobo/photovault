import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

extension ImportStage {
    /// Done when every file was decided and no upload of the job is waiting or running. Written
    /// together with its one activity row. A deferred job does not hold the import: the sweeper
    /// brings it back later and the source stays readable.
    func finishWhenDone(_ source: SourceRecord) async throws -> Bool {
        let id = source.id
        let now = env.clock.now
        return try await env.store.write { db in
            guard (try ImportItemRepository.counts(db, sourceId: id)[.pending] ?? 0) == 0,
                  try Bool.fetchOne(db, sql: """
                    SELECT NOT EXISTS(SELECT 1 FROM asset a JOIN upload_job j ON j.asset_key = a.asset_key
                                      WHERE a.source_id = ? AND j.state IN ('pending', 'uploading'))
                    """, arguments: [id.rawValue]) == true else { return false }
            return try ImportCompletion.finish(db, id: id, as: .completed, now: now)
        }
    }
}
