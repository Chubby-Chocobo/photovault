import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Extension point for job kinds the eligibility pass does not create itself. Sidecar jobs are
/// created by their own planner (they need every original job to finish first, FR-93); it runs
/// inside the same transaction after the resource jobs of an asset were recomputed.
protocol JobPlanningExtension: Sendable {
    func plan(_ db: Database, asset: AssetRecord, destination: DestinationRecord, eligible: Bool,
              plannedTypes: [ResourceType], context: PipelineContext) throws
}

/// Recomputes upload jobs from the database: scope, rules and settings decide (spec 8.8).
/// Widening enqueues from stored rows without any rescan (FR-19, FR-06); narrowing cancels.
struct EligibilityService: Sendable {
    let env: EngineEnvironment
    var extensions: [any JobPlanningExtension] = []

    init(env: EngineEnvironment, extensions: [any JobPlanningExtension] = []) {
        self.env = env
        self.extensions = extensions
    }

    /// Destinations that must not receive jobs right now (FR-51 recovery in progress).
    static func isRecovering(_ destination: DestinationRecord) -> Bool {
        destination.recoveryRequired || destination.status == .paused(.recovering)
    }

    /// Job origin by priority class (8.4): post-baseline assets are incremental.
    static func origin(for asset: AssetRecord, destination: DestinationRecord, backfill: JobOrigin) -> JobOrigin {
        Eligibility.inWindow(asset, destination) ? .incremental : backfill
    }

    /// In-transaction recompute for one asset. Returns the number of job rows written.
    @discardableResult
    static func recompute(
        _ db: Database, asset: AssetRecord, context: PipelineContext, only: DestinationID? = nil,
        backfillOrigin: JobOrigin = .backfill, extensions: [any JobPlanningExtension] = []
    ) throws -> Int {
        // A deleted asset is no longer eligible anywhere. Each job that has not uploaded anything
        // (pending or deferred) is cancelled on its own; done jobs stay, the backup is never touched (T23).
        if asset.deletedAt != nil {
            var cancelled = 0
            let destinationIds = Set(context.destinations.map(\.id))
            for job in try JobRepository.fetchAll(db, assetKey: asset.assetKey)
            where destinationIds.contains(job.destinationId) && [.pending, .deferred].contains(job.state) {
                _ = try JobRepository.apply(db, .cancel, to: job.identity, now: context.now)
                cancelled += 1
            }
            return cancelled
        }
        let resources = try ResourceRepository.fetchAll(db, key: asset.assetKey)
        let descriptors = resources.map(\.descriptor)
        var written = 0
        for destination in context.destinations where only == nil || destination.id == only {
            if isRecovering(destination) { continue }
            let eligible = Eligibility.isEligible(asset, destination, settings: context.settings, archiveTimeZone: context.timeZone)
            let planned = eligible
                ? ResourcePlanner.plannedTypes(for: descriptors, mediaType: asset.mediaType, settings: context.settings, rules: destination.rules)
                : []
            let origin = origin(for: asset, destination: destination, backfill: backfillOrigin)
            for type in planned {
                guard let resource = resources.first(where: { $0.type == type }) else { continue }
                let desired = JobTransitions.Desired(
                    identity: JobIdentity(destinationId: destination.id, assetKey: asset.assetKey, resType: type),
                    origin: origin, targetGen: resource.contentGen)
                if try JobRepository.upsert(db, desired: desired, now: context.now) != nil { written += 1 }
            }
            if planned.isEmpty {
                written += try JobRepository.cancelAll(db, assetKey: asset.assetKey, destinationId: destination.id, now: context.now).count
            } else {
                for job in try JobRepository.fetchAll(db, assetKey: asset.assetKey)
                where job.destinationId == destination.id && !job.resType.isSidecar && !planned.contains(job.resType)
                    && [.pending, .deferred].contains(job.state) {
                    _ = try JobRepository.apply(db, .cancel, to: job.identity, now: context.now)
                    written += 1
                }
            }
            for planner in extensions {
                try planner.plan(db, asset: asset, destination: destination, eligible: eligible, plannedTypes: planned, context: context)
            }
        }
        return written
    }

    /// Recomputes one asset in its own transaction.
    @discardableResult
    func recompute(assetKey: AssetKey) async throws -> Int {
        let snapshot = await env.settingsSnapshot()
        let env = env
        let extensions = extensions
        return try await env.store.write { db in
            guard let asset = try AssetRepository.fetch(db, key: assetKey) else { return 0 }
            let context = try env.context(db, snapshot)
            return try Self.recompute(db, asset: asset, context: context, extensions: extensions)
        }
    }

    /// Recomputes every live asset (settings, rule or scope change; new destination), in batches.
    /// - Parameter backfillOrigin: origin for jobs of assets older than the destination's baseline.
    @discardableResult
    func recomputeAll(destination: DestinationID? = nil, backfillOrigin: JobOrigin = .backfill) async throws -> Int {
        var cursor = ""
        var written = 0
        let env = env
        let extensions = extensions
        while true {
            try Task.checkCancellation()
            let snapshot = await env.settingsSnapshot()
            let start = cursor
            let batch: (written: Int, last: String?) = try await env.store.write { db in
                let keys = try EngineQueries.liveAssetKeys(db, after: start, limit: 500)
                guard !keys.isEmpty else { return (0, nil) }
                let context = try env.context(db, snapshot)
                var count = 0
                for key in keys {
                    guard let asset = try AssetRepository.fetch(db, key: key) else { continue }
                    count += try Self.recompute(db, asset: asset, context: context, only: destination,
                                                backfillOrigin: backfillOrigin, extensions: extensions)
                }
                return (count, keys.last?.rawValue)
            }
            guard let last = batch.last else { return written }
            written += batch.written
            cursor = last
        }
    }
}
