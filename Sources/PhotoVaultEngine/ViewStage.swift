import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Step 7, view half (spec 8.13): the shortcut trees of Drive destinations follow the database.
/// Assets reach it through the dirty queue (upload done, Favorite, EXIF, geocode, device table)
/// and through sweeps (a view switched on, "Dựng lại view"). It runs after the uploads of the round
/// and shares the metadata lane of the token bucket, so it never starves uploads.
struct ViewStage: CycleStage {
    let env: EngineEnvironment
    let uploader: UploadRunner
    let resourceGuard: ResourceGuard
    var step: CycleStep { .sidecarsAndViews }

    private static let disabledPrefix = "views_disabled:"
    private static let rebuildKey = "rebuild:view"
    private static let preparedKey = "rebuild:view:prepared"

    private struct Target: Sendable {
        var record: DestinationRecord
        var destination: any ViewDestination
    }

    static func isDisabled(_ db: Database, _ id: DestinationID) throws -> Bool {
        try KeyValueRepository.int(db, disabledPrefix + id.rawValue) == 1
    }

    /// FR-103: the destination refuses shortcuts, so views are off for it. The scope is never raised.
    static func disable(_ db: Database, _ id: DestinationID, now: Date) throws {
        try KeyValueRepository.set(db, disabledPrefix + id.rawValue, 1)
        try ActivityRepository.record(db, ActivityEvent(
            at: now, kind: .notice, destinationId: id, message: tr(
                vi: "Google Drive không cho tạo shortcut với quyền hiện tại; các view đã tắt",
                en: "Google Drive does not allow creating shortcuts with the current permission; views are turned off")))
    }

    /// Queues a full pass that also restores shortcuts the owner removed ("Dựng lại view").
    static func requestRebuild(_ db: Database) throws {
        try KeyValueRepository.set(db, rebuildKey, 1)
        try KeyValueRepository.set(db, preparedKey, nil)
        try DirtyQueue.requestSweep(db, [.view])
    }

    func run(trigger: SyncTrigger) async throws -> Bool {
        let settings = await env.settingsSnapshot().settings
        // Nothing can ever use the queued work: drop it (a view switched on or a Drive added queues a sweep).
        guard try await hasViewDestination(), !ViewPlanner.enabledViews(settings).isEmpty else {
            try await env.store.write { db in
                try DirtyQueue.clear(db, .view, ids: try DirtyQueue.pending(db, .view, limit: 100_000))
            }
            return false
        }
        // A destination that is paused or offline keeps the work queued.
        let targets = try await viewTargets()
        guard !targets.isEmpty else { return false }
        let rebuilding = try await env.store.read { db in try KeyValueRepository.int(db, Self.rebuildKey) } == 1
        // A destination that cannot answer now keeps the rebuild queued: no folder is created blindly.
        if rebuilding, !(try await prepareRebuild(targets)) { return false }
        var worked = false
        for target in targets {
            let executor = try await executor(for: target)
            switch try await executor.finishTrashes() {
            case .completed: continue
            case .disabled:
                let id = target.record.id
                let now = env.clock.now
                try await env.store.write { db in try Self.disable(db, id, now: now) }
            case .retryLater, .stopped: return worked
            }
        }
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let limit = 200 + seen.count
            let ids: [String] = try await env.store.write { db in
                try DirtyQueue.promoteSweep(db, .view)
                return try DirtyQueue.pending(db, .view, limit: limit)
            }.filter { !seen.contains($0) }
            if ids.isEmpty { break }
            seen.formUnion(ids)
            let keys = ids.compactMap(AssetKey.init(rawValue:))
            if rebuilding { try await restoreRemoved(keys) }
            var failed = Set<AssetKey>()
            for target in try await viewTargets() {
                let results = try await process(target, keys: keys)
                for (key, result) in results where result != .completed { failed.insert(key) }
                if results.values.contains(.completed) { worked = true }
            }
            let done = ids.filter { id in AssetKey(rawValue: id).map { !failed.contains($0) } ?? true }
            try await env.store.write { db in try DirtyQueue.clear(db, .view, ids: done) }
        }
        if rebuilding { try await finishRebuildIfDone() }
        return worked
    }

    // MARK: Targets

    /// A destination that could show views if it were available and views were not refused.
    private func hasViewDestination() async throws -> Bool {
        let records = try await env.store.read { db in try DestinationRepository.fetchAll(db).filter { try !Self.isDisabled(db, $0.id) } }
        for record in records {
            if let destination = await env.destinations.destination(for: record.id), destination.capabilities.supportsViews,
               destination is any ViewDestination { return true }
        }
        return false
    }

    private func viewTargets() async throws -> [Target] {
        let records = try await env.store.read { db in
            try DestinationRepository.fetchAll(db).filter { try $0.acceptsUploads && !Self.isDisabled(db, $0.id) }
        }
        var targets: [Target] = []
        for record in records {
            guard let destination = await env.destinations.destination(for: record.id), destination.capabilities.supportsViews,
                  let viewDestination = destination as? any ViewDestination else { continue }
            targets.append(Target(record: record, destination: viewDestination))
        }
        return targets
    }

    private func executor(for target: Target) async throws -> ViewExecutor {
        ViewExecutor(
            env: env, record: target.record, destination: target.destination,
            ensurer: await uploader.ensurer(for: target.record, destination: target.destination), resourceGuard: resourceGuard)
    }

    private func process(_ target: Target, keys: [AssetKey]) async throws -> [AssetKey: ViewExecutor.Result] {
        let snapshot = await env.settingsSnapshot()
        let env = env
        let record = target.record
        let plan = try await env.store.read { db in
            try ViewPlanner.plan(db, keys: keys, destination: record, context: try env.context(db, snapshot))
        }
        let operations = ViewDiff.operations(desired: plan.desired, current: plan.current)
        let executor = try await executor(for: target)
        try await executor.syncFolderNames(plan)
        guard !operations.isEmpty else { return [:] }
        let results = try await executor.run(operations, plan: plan)
        if results.values.contains(.disabled) {
            let now = env.clock.now
            try await env.store.write { db in try Self.disable(db, record.id, now: now) }
        }
        return results
    }

    // MARK: Rebuild

    /// The owner's removals in Drive are learned first (see `ViewRebuildPreparation`), once per rebuild.
    /// Returns false when a destination has to be asked again later.
    private func prepareRebuild(_ targets: [Target]) async throws -> Bool {
        guard try await env.store.read({ db in try KeyValueRepository.int(db, Self.preparedKey) }) != 1 else { return true }
        for target in targets {
            let ensurer = await uploader.ensurer(for: target.record, destination: target.destination)
            let preparation = ViewRebuildPreparation(env: env, record: target.record, destination: target.destination, ensurer: ensurer)
            guard try await preparation.run() else { return false }
        }
        try await env.store.write { db in try KeyValueRepository.set(db, Self.preparedKey, 1) }
        return true
    }

    private func restoreRemoved(_ keys: [AssetKey]) async throws {
        try await env.store.write { db in
            for key in keys {
                try db.execute(sql: """
                    UPDATE shortcut SET state = 'trashed', shortcut_id = NULL WHERE asset_key = ? AND state = 'userRemoved'
                    """, arguments: [key.rawValue])
            }
        }
    }

    private func finishRebuildIfDone() async throws {
        try await env.store.write { db in
            guard try DirtyQueue.sweepCursor(db, .view) == nil, try DirtyQueue.pending(db, .view, limit: 1).isEmpty else { return }
            try KeyValueRepository.set(db, Self.rebuildKey, nil)
            try KeyValueRepository.set(db, Self.preparedKey, nil)
        }
    }
}
