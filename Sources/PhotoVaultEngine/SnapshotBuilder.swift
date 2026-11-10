import Foundation
import GRDB
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
        var imports: [ImportSnapshot]
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
                bytes: try EngineQueries.uploadedBytes(db), totals: byDestination.values.reduce(EngineQueries.JobCounts(), +),
                imports: try Self.imports(db))
        }
    }

    /// Folder imports, newest first. Upload progress is counted only while a job is open.
    static func imports(_ db: Database) throws -> [ImportSnapshot] {
        try SourceRepository.fetchAll(db).filter { $0.mode == .oneTime }.reversed().map { source in
            let counts = try ImportItemRepository.counts(db, sourceId: source.id)
            let pending = counts[.pending] ?? 0
            let found = counts.values.reduce(0, +)
            let progress = source.status.isOpen ? try EngineQueries.importUploadProgress(db, sourceId: source.id) : (done: 0, total: 0)
            return ImportSnapshot(
                id: source.id, kind: source.kind, account: source.config.account, statusReason: source.statusReason,
                displayName: source.displayName, status: source.status, createdAt: source.createdAt,
                finishedAt: source.finishedAt, found: found, processed: found - pending, imported: counts[.imported] ?? 0,
                duplicates: counts[.duplicate] ?? 0, unsupported: counts[.unsupported] ?? 0, failed: counts[.failed] ?? 0,
                filesUploaded: progress.done, filesTotal: progress.total)
        }
    }
}
