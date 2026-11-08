import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Executes view operations at one Drive destination (FR-100..103, spec 8.13). Every step is
/// persisted before its side effect: shortcut ids are reserved and saved before `createShortcut`,
/// `movePending` / `trashPending` before a move or trash. After a crash the same operation runs
/// again; an `alreadyExists` answer is verified with a probe, so no shortcut is created twice.
struct ViewExecutor: Sendable {
    enum Result: Sendable, Equatable {
        case completed
        /// Not finished (rate limit or a retryable error); the asset stays queued.
        case retryLater
        /// The destination refuses shortcuts: views are off for it.
        case disabled
        /// A destination-level error ended the pass.
        case stopped
    }

    let env: EngineEnvironment
    let record: DestinationRecord
    let destination: any ViewDestination
    let ensurer: FolderEnsurer
    let resourceGuard: ResourceGuard

    private var layout: any LayoutPolicy { env.layout }

    // MARK: Entry points

    func run(_ operations: [ViewOperation], plan: ViewPlan) async throws -> [AssetKey: Result] {
        var results: [AssetKey: Result] = [:]
        var halted: Result?
        for operation in operations {
            let key = Self.key(of: operation)
            let outcome: Result
            if let halted {
                outcome = halted
            } else if await resourceGuard.admitMetadataWrite() {
                outcome = try await perform(operation, plan: plan)
                if outcome == .disabled || outcome == .stopped { halted = outcome }
            } else {
                outcome = .retryLater
                halted = .retryLater
            }
            if results[key] == nil || results[key] == .completed { results[key] = outcome }
        }
        return results
    }

    /// Finishes trashes that were persisted but not confirmed.
    func finishTrashes() async throws {
        let id = record.id
        for shortcut in try await env.store.read({ db in try ShortcutRepository.fetch(db, destinationId: id, state: .trashPending) }) {
            guard await resourceGuard.admitMetadataWrite() else { return }
            _ = try await trash(shortcut)
        }
    }

    private static func key(of operation: ViewOperation) -> AssetKey {
        switch operation {
        case .trash(_, let key), .move(_, let key, _): key
        case .create(let item): item.assetKey
        }
    }

    private func perform(_ operation: ViewOperation, plan: ViewPlan) async throws -> Result {
        let id = record.id
        do {
            switch operation {
            case .trash(let view, let key):
                guard let shortcut = try await env.store.read({ db in try ShortcutRepository.fetch(db, destinationId: id, view: view, assetKey: key) })
                else { return .completed }
                return try await trash(shortcut)
            case .move(let view, let key, let parent):
                guard let shortcut = try await env.store.read({ db in try ShortcutRepository.fetch(db, destinationId: id, view: view, assetKey: key) }),
                      let path = plan.paths[.init(view: view, assetKey: key)] else { return .completed }
                return try await move(shortcut, to: parent, path: path)
            case .create(let item):
                guard let path = plan.paths[.init(view: item.view, assetKey: item.assetKey)], let target = item.targetId else { return .completed }
                return try await create(item, target: target, name: plan.names[item.assetKey], path: path)
            }
        } catch {
            if error is EngineAbort || error is CancellationError { throw error }
            return try await handle(error, operation: operation)
        }
    }

    // MARK: Operations

    private func create(_ item: DesiredShortcut, target: String, name: String?, path: ViewPath) async throws -> Result {
        let id = record.id
        let chain = layout.viewFolderChain(path)
        try await queueRenames(chain)
        let parent = try await ensurer.ensure(chain, view: item.view)
        let existing = try await env.store.read { db in
            try ShortcutRepository.fetch(db, destinationId: id, view: item.view, assetKey: item.assetKey)
        }
        let reserved: String
        if let existing, existing.state == .pending, let kept = existing.shortcutId {
            reserved = kept
        } else {
            guard let fresh = try await destination.reserveIds(count: 1, kind: .shortcuts).first else {
                throw DestinationError.itemRejected(reason: "no shortcut id reserved")
            }
            reserved = fresh
        }
        var shortcut = ShortcutRecord(
            destinationId: id, view: item.view, assetKey: item.assetKey, targetId: target, shortcutId: reserved,
            parentLogical: item.parentLogical, state: .pending, attempts: existing?.attempts ?? 0)
        try await save(shortcut)
        let request = ShortcutRequest(
            reservedId: reserved, targetId: target, parent: parent, name: name ?? item.assetKey.identifier,
            appProperties: AppPropertyCodec.shortcutProperties(assetKey: item.assetKey, view: item.view, parentLogical: item.parentLogical))
        do {
            _ = try await destination.createShortcut(request)
        } catch DestinationError.alreadyExists(let existingId) {
            guard let found = try await destination.probe(remoteId: existingId.isEmpty ? reserved : existingId), found.kind == .shortcut,
                  found.shortcutTargetId == target, !found.trashed, found.parentIds.contains(parent.remoteId) else {
                throw DestinationError.itemRejected(reason: "reserved shortcut id in use")
            }
        }
        shortcut.state = .done
        shortcut.attempts = 0
        try await save(shortcut)
        return .completed
    }

    private func move(_ shortcut: ShortcutRecord, to parentLogical: String, path: ViewPath) async throws -> Result {
        guard let shortcutId = shortcut.shortcutId else { return .completed }
        let chain = layout.viewFolderChain(path)
        try await queueRenames(chain)
        let to = try await ensurer.ensure(chain, view: shortcut.view)
        let id = record.id
        let rootId = FolderRefResolver.rootId(record)
        let fromPath = shortcut.parentLogical ?? ""
        let from = try await env.store.read { db in
            try FolderRefResolver.ref(db, destinationId: id, logicalPath: fromPath, rootId: rootId)
        }
        var moving = shortcut
        moving.state = .movePending
        try await save(moving)
        _ = try await destination.moveShortcut(remoteId: shortcutId, from: from, to: to)
        moving.state = .done
        moving.parentLogical = parentLogical
        moving.attempts = 0
        try await save(moving)
        return .completed
    }

    private func trash(_ shortcut: ShortcutRecord) async throws -> Result {
        var trashing = shortcut
        if let shortcutId = shortcut.shortcutId {
            trashing.state = .trashPending
            try await save(trashing)
            do {
                try await destination.trashShortcut(remoteId: shortcutId)
            } catch DestinationError.notFound {
                // Already gone: nothing left to trash.
            }
        }
        trashing.state = .trashed
        try await save(trashing)
        return .completed
    }

    // MARK: Helpers

    /// Queues the renames of view folders whose display name changed (device renamed, language
    /// changed) even when no shortcut has to move.
    func syncFolderNames(_ plan: ViewPlan) async throws {
        for path in Set(plan.paths.values) { try await queueRenames(layout.viewFolderChain(path)) }
    }

    /// A view level whose display name changed is renamed in place; shortcuts inside keep pointing
    /// at the same folder because paths are logical keys.
    private func queueRenames(_ chain: [FolderLevel]) async throws {
        let id = record.id
        let now = env.clock.now
        try await env.store.write { db in
            for level in chain {
                guard let row = try RemoteFolderRepository.fetch(db, destinationId: id, logicalPath: level.logicalPath),
                      row.created, row.displayName != level.displayName else { continue }
                try MoveJobPlanner.enqueueRename(db, destinationId: id, logicalPath: level.logicalPath, to: level.displayName, now: now)
            }
        }
    }

    private func save(_ shortcut: ShortcutRecord) async throws {
        try await env.store.write { db in try ShortcutRepository.save(db, shortcut) }
    }

    // MARK: Errors

    private func handle(_ error: any Error, operation: ViewOperation) async throws -> Result {
        guard let failure = error as? DestinationError else {
            env.log.log(.error, category: "view", "unexpected error type=\(type(of: error))")
            return .retryLater
        }
        env.log.log(.notice, category: "view", "view operation failed error=\(failure)")
        switch failure {
        case .viewsNotPermitted:
            return .disabled
        case .folderTrashed(let path), .folderMissing(let path):
            // View folders are not backup data: the owner removed it, so what was inside is theirs now.
            try await ensurer.invalidate(logicalPath: path)
            try await markUserRemoved(under: path, operation: operation)
            return .completed
        case .notFound:
            if case .move(let view, let key, _) = operation { try await markUserRemoved(view: view, key: key) }
            return .completed
        default:
            if case .destinationLevel(let status) = ErrorClassifier.classify(failure) {
                let id = record.id
                let now = env.clock.now
                if let status { try await env.store.write { db in try DestinationRepository.setStatus(db, id: id, status: status, now: now) } }
                return .stopped
            }
            try await countFailure(operation)
            return .retryLater
        }
    }

    private func markUserRemoved(under path: String, operation: ViewOperation) async throws {
        let id = record.id
        try await env.store.write { db in
            try db.execute(sql: """
                UPDATE shortcut SET state = 'userRemoved'
                WHERE destination_id = ? AND (parent_logical = ? OR parent_logical LIKE ? ESCAPE '\\')
                  AND state IN ('pending', 'done', 'movePending', 'failed')
                """, arguments: [id.rawValue, path, path.replacingOccurrences(of: "_", with: "\\_") + "/%"])
        }
        if case .create(let item) = operation { try await markUserRemoved(view: item.view, key: item.assetKey) }
    }

    private func markUserRemoved(view: ViewKind, key: AssetKey) async throws {
        let id = record.id
        try await env.store.write { db in
            guard var shortcut = try ShortcutRepository.fetch(db, destinationId: id, view: view, assetKey: key) else { return }
            shortcut.state = .userRemoved
            try ShortcutRepository.save(db, shortcut)
        }
    }

    private func countFailure(_ operation: ViewOperation) async throws {
        let id = record.id
        let (view, key): (ViewKind, AssetKey)
        switch operation {
        case .trash(let v, let k), .move(let v, let k, _): (view, key) = (v, k)
        case .create(let item): (view, key) = (item.view, item.assetKey)
        }
        try await env.store.write { db in
            guard var shortcut = try ShortcutRepository.fetch(db, destinationId: id, view: view, assetKey: key) else { return }
            shortcut.attempts += 1
            if shortcut.attempts > MoveJob.maxAttempts { shortcut.state = .failed }
            try ShortcutRepository.save(db, shortcut)
        }
    }
}
