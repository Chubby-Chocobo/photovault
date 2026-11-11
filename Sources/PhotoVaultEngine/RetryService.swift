import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Owner-triggered retries of jobs the engine gave up on for now. Only the existing transitions are used: a
/// deferred job is retried as after its 24-hour wait, a skipped one as the owner's "retry skipped". Nothing at a
/// destination is deleted and the Photos library is not touched.
struct RetryService: Sendable {
    let env: EngineEnvironment

    /// Deferred jobs go back to `pending` (the cycle does the same after 24 hours). Export and disk
    /// counters are cleared so the retry is a fresh start.
    @discardableResult
    func retryDeferred(_ id: DestinationID?) async throws -> Int {
        let now = env.clock.now
        return try await env.store.write { db in
            var count = 0
            for job in try JobRepository.fetch(db, state: .deferred, destinationId: id) where try Self.retry(db, job, now: now) {
                count += 1
            }
            // A resource marked too large for the disk is re-armed as a whole, whichever of its
            // jobs (pending, or deferred for that reason) the owner's retry reached.
            for resource in try EngineQueries.tooLargeResources(db) {
                let waiting = try EngineQueries.jobs(db, key: resource.assetKey, type: resource.type, states: [.pending, .deferred])
                guard waiting.contains(where: { id == nil || $0.destinationId == id }) else { continue }
                try EngineQueries.clearTooLarge(db, key: resource.assetKey, type: resource.type)
                for job in waiting where job.state == .deferred && job.stateReason == .tooLargeForDisk {
                    _ = try JobRepository.apply(db, .retryDeferred, to: job.identity, now: now)
                    count += 1
                }
            }
            return count
        }
    }

    /// Skipped jobs go back to `pending`; a known `remote_id` is kept so nothing is uploaded twice.
    @discardableResult
    func retrySkipped(_ id: DestinationID?) async throws -> Int {
        let now = env.clock.now
        return try await env.store.write { db in
            var count = 0
            for job in try JobRepository.fetch(db, state: .skipped, destinationId: id) where try Self.retry(db, job, now: now) {
                count += 1
            }
            return count
        }
    }

    /// The given files, from the history: each deferred or skipped one is retried; any other state is left alone.
    /// The backfill runs they belong to wait for them again.
    @discardableResult
    func retry(_ identities: [JobIdentity]) async throws -> Int {
        let now = env.clock.now
        return try await env.store.write { db in
            var count = 0
            var runs = Set<Int64>()
            for identity in identities {
                guard let job = try JobRepository.fetch(db, identity: identity), try Self.retry(db, job, now: now) else { continue }
                count += 1
                if let run = job.backfillRunId, job.origin == .backfill || job.origin == .destinationBackfill { runs.insert(run) }
            }
            try BackfillRunRepository.reopen(db, runIds: runs)
            return count
        }
    }

    /// One job through the transition the owner's retry has always used, judged on its state now (an earlier retry in
    /// the same transaction may have moved it). False when it is neither deferred nor skipped.
    static func retry(_ db: Database, _ snapshot: UploadJob, now: Date) throws -> Bool {
        guard let job = try JobRepository.fetch(db, identity: snapshot.identity) else { return false }
        switch job.state {
        case .deferred:
            _ = try JobRepository.apply(db, .retryDeferred, to: job.identity, now: now)
            if job.stateReason == .exportFailures { try EngineQueries.clearExportFailures(db, key: job.assetKey, type: job.resType) }
            if job.stateReason == .tooLargeForDisk {
                // The size mark belongs to the resource: the jobs of the other destinations that waited for it are
                // re-armed with it, or nothing would ever retry them (the sweeper skips this reason).
                try EngineQueries.clearTooLarge(db, key: job.assetKey, type: job.resType)
                for other in try EngineQueries.jobs(db, key: job.assetKey, type: job.resType, states: [.deferred])
                where other.stateReason == .tooLargeForDisk {
                    _ = try JobRepository.apply(db, .retryDeferred, to: other.identity, now: now)
                }
            }
            return true
        case .skipped:
            _ = try JobRepository.apply(db, .retrySkipped, to: job.identity, now: now)
            return true
        default:
            return false
        }
    }
}
