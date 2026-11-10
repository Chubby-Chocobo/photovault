import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Builds the sidecar of one asset for one destination from the database. The same inputs always
/// give the same bytes; the content differs per destination because it lists that destination's
/// resources (FR-90, FR-91).
enum SidecarFactory {
    static func build(
        _ db: Database, asset: AssetRecord, destinationId: DestinationID, type: ResourceType, settings: GlobalSettings,
        timeZone: TimeZone, nameBuilder: NameStemBuilder
    ) throws -> SidecarFile? {
        guard let placement = asset.placement else { return nil }
        let resources = try ResourceRepository.fetchAll(db, key: asset.assetKey)
        let jobs = try JobRepository.fetchAll(db, assetKey: asset.assetKey)
            .filter { $0.destinationId == destinationId && !$0.resType.isSidecar && $0.state != .cancelled }
        let described = jobs.compactMap { job -> SidecarResource? in
            guard let resource = resources.first(where: { $0.type == job.resType }) else { return nil }
            return SidecarResource(
                type: resource.type, kind: resource.kind, originalName: resource.originalFilename,
                backupName: job.remoteName ?? nameBuilder.fileName(stem: placement.nameStem, resource: resource),
                size: resource.sizeBytes, md5: resource.md5, sha256: resource.sha256, state: job.state)
        }
        let input = SidecarInput(
            asset: asset, albumTitles: try AssetRepository.albums(db, for: asset.assetKey).map(\.albumTitle),
            place: try OrganizationLookups.place(db, asset: asset, settings: settings),
            deviceDisplayName: try OrganizationLookups.deviceName(db, asset: asset), resources: described, archiveTimeZone: timeZone,
            source: try sourceBlock(db, asset: asset))
        return type == .sidecarXmp ? SidecarBuilder.buildXMP(input) : SidecarBuilder.buildJSON(input)
    }

    /// Where an imported asset came from; nil for Photos, whose sidecars carry no such block.
    private static func sourceBlock(_ db: Database, asset: AssetRecord) throws -> SidecarSource? {
        guard asset.sourceId != .photos else { return nil }
        guard let source = try SourceRepository.fetch(db, id: asset.sourceId),
              let primary = try ImportItemRepository.primary(db, assetKey: asset.assetKey, preferring: asset.sourceId) else { return nil }
        let kind = source.kind.rawValue
        return SidecarSource(kind: kind, name: source.sidecarName, path: primary.relativePath, dateSource: primary.dateSource)
    }

    /// Hash in the form the destination verifies, comparable with `job.uploaded_hash`.
    static func hash(_ file: SidecarFile, kind: DestinationKind) -> String { kind == .googleDrive ? file.md5 : file.sha256 }
}

/// Creates and refreshes sidecar jobs inside the eligibility transaction (FR-93). The first
/// sidecar waits until every original job of the asset at the destination is finished; afterwards
/// the job's own `target_gen` is raised only when the generated content differs from what the
/// destination holds, so an unchanged sidecar is never uploaded again.
struct SidecarPlanner: JobPlanningExtension {
    func plan(_ db: Database, asset: AssetRecord, destination: DestinationRecord, eligible: Bool,
              plannedTypes: [ResourceType], context: PipelineContext) throws {
        let wanted = eligible
            ? ResourcePlanner.plannedSidecars(settings: context.settings, rules: destination.rules, hasPlannedResources: !plannedTypes.isEmpty)
            : []
        let jobs = try JobRepository.fetchAll(db, assetKey: asset.assetKey).filter { $0.destinationId == destination.id }
        for job in jobs where job.resType.isSidecar && !wanted.contains(job.resType) && [.pending, .deferred].contains(job.state) {
            _ = try JobRepository.apply(db, .cancel, to: job.identity, now: context.now)
        }
        // A provisional category means the header was not read yet: the sidecar would be written twice.
        guard !wanted.isEmpty, asset.placement != nil, !asset.categoryProvisional else { return }
        let resourceJobs = jobs.filter { !$0.resType.isSidecar && $0.state != .cancelled }
        let originals = resourceJobs.filter { $0.kind == .original }
        let gating = originals.isEmpty ? resourceJobs : originals
        guard !gating.isEmpty, gating.allSatisfy({ $0.state.isFinished }), resourceJobs.contains(where: { $0.state == .done }) else { return }
        for type in wanted {
            let existing = jobs.first { $0.resType == type }
            try plan(db, type: type, existing: existing, asset: asset, destination: destination, context: context)
        }
    }

    private func plan(
        _ db: Database, type: ResourceType, existing: UploadJob?, asset: AssetRecord, destination: DestinationRecord,
        context: PipelineContext
    ) throws {
        let identity = JobIdentity(destinationId: destination.id, assetKey: asset.assetKey, resType: type)
        let origin = EligibilityService.origin(for: asset, destination: destination, backfill: .backfill)
        guard let existing else {
            try JobRepository.upsert(db, desired: .init(identity: identity, origin: origin, targetGen: 1), now: context.now)
            return
        }
        switch existing.state {
        case .cancelled:
            try JobRepository.upsert(db, desired: .init(identity: identity, origin: origin, targetGen: existing.targetGen), now: context.now)
        case .done, .uploading:
            // A sidecar still being sent is raised once beyond the generation in flight.
            if existing.state == .uploading, existing.targetGen > (existing.uploadingGen ?? existing.targetGen) { return }
            guard let file = try SidecarFactory.build(
                db, asset: asset, destinationId: destination.id, type: type, settings: context.settings, timeZone: context.timeZone,
                nameBuilder: context.nameBuilder) else { return }
            let built = SidecarFactory.hash(file, kind: destination.kind)
            guard existing.uploadedHash != built else {
                try RecoveredSidecar.forget(db, identity: identity)
                return
            }
            // The place is still being looked up (a database loss empties the geocode cache): the sidecar is
            // refreshed once the answer arrives, which marks the asset again, instead of twice.
            if context.geocodingAvailable, try OrganizationLookups.placeIsPending(db, asset: asset, settings: context.settings) { return }
            if try RecoveredSidecar.isStillCurrent(db, identity: identity, builtHash: built) { return }
            try JobRepository.upsert(db, desired: .init(identity: identity, origin: .refresh, targetGen: existing.targetGen + 1), now: context.now)
        case .pending, .deferred, .skipped, .missingRemote:
            return
        }
    }
}

/// Step 7, sidecar half: re-plans the assets whose resources finished, whose geocode arrived, or
/// that a sweep (language, device names, reconciliation) reached.
struct SidecarStage: CycleStage {
    let env: EngineEnvironment
    var step: CycleStep { .sidecarsAndViews }

    func run(trigger: SyncTrigger) async throws -> Bool {
        let before = try await env.store.read { db in try OrganizationQueries.sidecarVersion(db) }
        let env = env
        while true {
            try Task.checkCancellation()
            let snapshot = await env.settingsSnapshot()
            let more: Bool = try await env.store.write { db in
                try DirtyQueue.promoteSweep(db, .sidecar)
                let ids = try DirtyQueue.pending(db, .sidecar, limit: 200)
                guard !ids.isEmpty else { return false }
                let context = try env.context(db, snapshot)
                for id in ids {
                    guard let key = AssetKey(rawValue: id), let asset = try AssetRepository.fetch(db, key: key), asset.deletedAt == nil
                    else { continue }
                    try EligibilityService.recompute(db, asset: asset, context: context, extensions: [SidecarPlanner()])
                }
                try DirtyQueue.clear(db, .sidecar, ids: ids)
                return true
            }
            if !more { break }
        }
        return try await env.store.read { db in try OrganizationQueries.sidecarVersion(db) } != before
    }
}

/// A sidecar that recovery found at a destination whose files cannot be read back (Drive). The hashes
/// and camera fields it lists were lost with the database and cannot be restored, so what the app builds
/// next never equals it byte for byte. The first build after recovery is remembered; the sidecar is
/// written again only when a later build differs from that one, that is, when an input really changed.
enum RecoveredSidecar {
    private static func key(_ identity: JobIdentity) -> String {
        "sidecar-recovered:\(identity.destinationId.rawValue):\(identity.assetKey.rawValue):\(identity.resType.rawValue)"
    }

    static func remember(_ db: Database, identity: JobIdentity) throws {
        try KeyValueRepository.set(db, key(identity), "")
    }

    /// The build equals the file at the destination: nothing to remember any more.
    static func forget(_ db: Database, identity: JobIdentity) throws {
        try KeyValueRepository.set(db, key(identity), nil)
    }

    /// True while the sidecar at the destination stands. A changed build ends the memory, so the caller writes.
    static func isStillCurrent(_ db: Database, identity: JobIdentity, builtHash: String) throws -> Bool {
        guard let baseline = try KeyValueRepository.string(db, key(identity)) else { return false }
        if baseline.isEmpty {
            try KeyValueRepository.set(db, key(identity), builtHash)
            return true
        }
        if baseline == builtHash { return true }
        try KeyValueRepository.set(db, key(identity), nil)
        return false
    }
}
