import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Deferred jobs come back after 24 hours (retry) and are skipped after 30 days (8.3, FR-23).
/// `tooLargeForDisk` jobs are outside this cycle; the export worker revisits them.
struct DeferredJobSweeper: Sendable {
    let env: EngineEnvironment

    @discardableResult
    func sweep() async throws -> Int {
        let now = env.clock.now
        return try await env.store.write { db in
            var changed = 0
            for job in try JobRepository.fetch(db, state: .deferred) where job.stateReason != .tooLargeForDisk {
                if let since = job.deferredSince, now.timeIntervalSince(since) > JobTransitions.deferralLimit {
                    _ = try JobRepository.apply(db, .deferralExpired, to: job.identity, now: now)
                    changed += 1
                } else if let due = job.nextAttemptAt, due <= now {
                    _ = try JobRepository.apply(db, .retryDeferred, to: job.identity, now: now)
                    if job.stateReason == .exportFailures {
                        try EngineQueries.clearExportFailures(db, key: job.assetKey, type: job.resType)
                    }
                    changed += 1
                }
            }
            return changed
        }
    }
}
