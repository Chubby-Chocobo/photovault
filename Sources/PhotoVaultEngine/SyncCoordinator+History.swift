import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Owner commands of the History window. Retries go through the owner's existing retry transitions only
/// (`RetryService`); they run in the exclusive lane like every other owner command. Logs carry counts only.
extension SyncCoordinator {
    /// "Retry" on files of the history: each deferred or skipped one goes back to `pending`.
    @discardableResult
    public func retryFiles(_ jobs: [JobIdentity]) async throws -> Int {
        let count = try await exclusive { try await hardening.retry.retry(jobs) }
        env.log.log(.info, category: "history", "retried files=\(count)")
        await publish()
        return count
    }

    /// "Retry failed files" of one backfill run.
    @discardableResult
    public func retryFailedFiles(ofRun runId: Int64) async throws -> Int {
        let env = env
        let count = try await exclusive {
            let jobs = try await env.store.read { db in try BackfillRunRepository.failedJobs(db, runId: runId) }
            return try await hardening.retry.retry(jobs)
        }
        env.log.log(.info, category: "history", "retried run files=\(count)")
        await publish()
        return count
    }

    /// "Retry failed uploads" of one import. Files the import could not read are not retried here: importing the
    /// folder again reads them (files already backed up are recognised as duplicates).
    @discardableResult
    public func retryFailedUploads(ofImport sourceId: SourceID) async throws -> Int {
        let env = env
        let count = try await exclusive {
            let jobs = try await env.store.read { db in try ImportHistoryRepository.failedJobs(db, sourceId: sourceId) }
            return try await hardening.retry.retry(jobs)
        }
        env.log.log(.info, category: "history", "retried import files=\(count)")
        await publish()
        return count
    }
}
