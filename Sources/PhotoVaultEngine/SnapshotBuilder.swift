import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Builds the `EngineSnapshot` from the database.
struct SnapshotBuilder: Sendable {
    let env: EngineEnvironment

    struct Raw: Sendable {
        var scan: ScanState
        var destinations: [DestinationSnapshot]
        var backfill: (done: Int, total: Int)
        var bytes: Int64
        var totals: EngineQueries.JobCounts
    }

    func read() async throws -> Raw {
        try await env.store.read { db in
            var list: [DestinationSnapshot] = []
            let byDestination = try EngineQueries.jobCountsByDestination(db)
            for record in try DestinationRepository.fetchAll(db) {
                let counts = byDestination[record.id] ?? EngineQueries.JobCounts()
                list.append(DestinationSnapshot(
                    id: record.id, displayName: record.displayName, status: record.status, pending: counts.pending + counts.uploading,
                    deferred: counts.deferred, skipped: counts.skipped, missingRemote: counts.missingRemote,
                    lastSuccessAt: record.lastSuccessAt))
            }
            return Raw(
                scan: try KeyValueRepository.scanState(db), destinations: list, backfill: try EngineQueries.backfillProgress(db),
                bytes: try EngineQueries.uploadedBytes(db), totals: byDestination.values.reduce(EngineQueries.JobCounts(), +))
        }
    }
}
