import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// FR-47: a Drive root that is gone or in the trash pauses the destination; the engine never
/// recreates it. The owner either restores it or starts over in a new root. "Khôi phục giúp tôi"
/// untrashes the folders and the root the app created.
struct RootProblemService: Sendable {
    private static let newRootKey = "newroot:"

    let env: EngineEnvironment
    let forget: @Sendable (DestinationID) async -> Void
    let enqueue: @Sendable (DestinationID) async throws -> Void

    private func load(_ id: DestinationID) async throws -> (DestinationRecord, any RootManaging) {
        guard let record = try await env.store.read({ db in try DestinationRepository.fetch(db, id: id) }) else {
            throw StoreError.notFound("destination \(id)")
        }
        guard let destination = await env.destinations.destination(for: id), let managing = destination as? any RootManaging else {
            throw RootProblemError.unsupported
        }
        return (record, managing)
    }

    private static func isRootProblem(_ status: DestinationStatus) -> Bool {
        status == .paused(.rootMissing) || status == .paused(.rootTrashed)
    }

    func resolve(_ id: DestinationID, choice: RootProblemChoice) async throws {
        let (record, managing) = try await load(id)
        guard Self.isRootProblem(record.status) else { throw RootProblemError.notRootProblem }
        switch choice {
        case .ownerRestored: try await recheck(record, managing)
        case .uploadToNewRoot(let name): try await startOver(record, managing, name: name)
        }
    }

    private func recheck(_ record: DestinationRecord, _ managing: any RootManaging) async throws {
        guard let rootId = record.config.driveRootId else { throw RootProblemError.stillMissing }
        switch try await managing.checkRoot(remoteId: rootId) {
        case .missing: throw RootProblemError.stillMissing
        case .trashed: throw RootProblemError.stillTrashed
        case .ok:
            let id = record.id
            let now = env.clock.now
            try await env.store.write { db in try DestinationRepository.setStatus(db, id: id, status: .active, now: now) }
            await forget(id)
            await IntegrityChecker(env: env).healMissing(id, destination: managing)
        }
    }

    /// A new, empty root with a reserved id (persisted first, so a crash never makes two roots),
    /// then the old location is forgotten and everything is queued again per scope.
    private func startOver(_ record: DestinationRecord, _ managing: any RootManaging, name: String) async throws {
        let id = record.id
        let clean = NameSanitizer.sanitize(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.isEmpty else { throw EngineError.invalidState("empty root name") }
        let marker = Self.newRootKey + id.rawValue
        let stored = try await env.store.read { db in try KeyValueRepository.string(db, marker) }
        let reserved: String
        if let stored, !stored.isEmpty {
            reserved = stored
        } else {
            guard let fresh = try await managing.reserveIds(count: 1, kind: .files).first else {
                throw DestinationError.itemRejected(reason: "no root id reserved")
            }
            reserved = fresh
            try await env.store.write { db in try KeyValueRepository.set(db, marker, fresh) }
        }
        let zone = await env.settings.snapshot().timeZone
        let root: RemoteItem
        do {
            root = try await managing.createRoot(reservedId: reserved, name: clean, appProperties: AppPropertyCodec.rootProperties(archiveTimezone: zone))
        } catch DestinationError.alreadyExists {
            guard case .ok(let existing) = try await managing.checkRoot(remoteId: reserved) else { throw RootProblemError.stillMissing }
            root = existing
        }
        let now = env.clock.now
        try await env.store.write { db in
            guard var current = try DestinationRepository.fetch(db, id: id) else { throw StoreError.notFound("destination \(id)") }
            current.config.driveRootId = root.remoteId
            current.config.driveRootName = clean
            try DestinationRepository.save(db, current)
            try RecoveryTriggers.dropDestinationKnowledge(db, id: id)
            try DestinationRepository.setRecoveryRequired(db, id: id, false)
            try DestinationRepository.setStatus(db, id: id, status: .active, now: now)
            try KeyValueRepository.set(db, RecoveryTriggers.probeKey + id.rawValue, 1)
            try KeyValueRepository.set(db, RecoveryService.enqueueKey + id.rawValue, 1)
            try KeyValueRepository.set(db, marker, nil)
            try ActivityRepository.record(db, ActivityEvent(
                at: now, kind: .notice, destinationId: id, message: "Đã tạo thư mục gốc mới; mọi thứ sẽ được upload lại theo phạm vi"))
        }
        await forget(id)
        try await enqueue(id)
    }

    // MARK: Khôi phục giúp tôi

    /// Untrashes the root and every folder the app created. Returns how many items were restored.
    @discardableResult
    func untrashAppItems(_ id: DestinationID) async throws -> Int {
        let (record, managing) = try await load(id)
        var restored = 0
        if let rootId = record.config.driveRootId, case .trashed = try await managing.checkRoot(remoteId: rootId) {
            _ = try await managing.untrash(remoteId: rootId)
            restored += 1
        }
        var candidates = Set(try await env.store.read { db in
            try RemoteFolderRepository.fetchAll(db, destinationId: id).filter(\.created).compactMap(\.remoteId)
        })
        for try await item in managing.list(under: nil) where item.kind == .folder && item.trashed
            && item.appProperties[AppPropertyKey.schema] == AppPropertyCodec.schemaVersion {
            candidates.insert(item.remoteId)
        }
        for folderId in candidates.sorted() {
            try Task.checkCancellation()
            guard let item = try await managing.probe(remoteId: folderId), item.trashed else { continue }
            _ = try await managing.untrash(remoteId: folderId)
            restored += 1
        }
        let now = env.clock.now
        try await env.store.write { db in
            guard let current = try DestinationRepository.fetch(db, id: id), current.status == .paused(.folderTrashed) else { return }
            try DestinationRepository.setStatus(db, id: id, status: .active, now: now)
        }
        await forget(id)
        if restored > 0 { await IntegrityChecker(env: env).healMissing(id, destination: managing) }
        return restored
    }
}

/// FR-47: a backup folder answered 404 while writing. The branch is forgotten (the next write
/// creates it again); the files that were in it are `missingRemote` and the owner is told.
enum FolderGone {
    static func markBranchMissing(_ env: EngineEnvironment, destinationId: DestinationID, logicalPath: String) async throws {
        let now = env.clock.now
        let count: Int = try await env.store.write { db in
            var count = 0
            for job in try JobRepository.fetch(db, state: .done, destinationId: destinationId) {
                guard let parent = job.remoteLogicalParent, parent == logicalPath || parent.hasPrefix(logicalPath + "/") else { continue }
                _ = try JobRepository.apply(db, .missingAtDestination, to: job.identity, now: now)
                count += 1
            }
            if count > 0 {
                try ActivityRepository.record(db, ActivityEvent(
                    at: now, kind: .missingFile, destinationId: destinationId,
                    message: "Một thư mục sao lưu đã bị xoá ở đích; \(count) file cần xác nhận trước khi upload lại"))
            }
            return count
        }
        if count > 0 { env.log.log(.notice, category: "folders", "folder branch gone, \(count) files marked missing") }
    }
}

/// Owner-triggered retries of jobs the engine gave up on for now.
struct RetryService: Sendable {
    let env: EngineEnvironment

    /// Deferred jobs go back to `pending` (the cycle does the same after 24 hours). Export and disk
    /// counters are cleared so the retry is a fresh start.
    @discardableResult
    func retryDeferred(_ id: DestinationID?) async throws -> Int {
        let now = env.clock.now
        return try await env.store.write { db in
            var count = 0
            for job in try JobRepository.fetch(db, state: .deferred, destinationId: id) {
                _ = try JobRepository.apply(db, .retryDeferred, to: job.identity, now: now)
                if job.stateReason == .exportFailures { try EngineQueries.clearExportFailures(db, key: job.assetKey, type: job.resType) }
                if job.stateReason == .tooLargeForDisk { try EngineQueries.clearTooLarge(db, key: job.assetKey, type: job.resType) }
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
            for job in try JobRepository.fetch(db, state: .skipped, destinationId: id) {
                _ = try JobRepository.apply(db, .retrySkipped, to: job.identity, now: now)
                count += 1
            }
            return count
        }
    }
}
