import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// What a finished move or rename writes. The destination effect has already happened; these
/// functions persist it together with `inProgress → done` in one transaction.
enum MoveCommit {
    static func file(_ db: Database, move: MoveJob, identity: JobIdentity, parent: String, remoteId: String) throws {
        try OrganizationQueries.setRemoteLocation(db, identity: identity, parent: parent, remoteId: remoteId)
        if let id = move.id { try MoveJobRepository.complete(db, id: id) }
    }

    static func rename(_ db: Database, move: MoveJob, folder: RemoteFolder, newRemoteId: String?) throws {
        var renamed = folder
        renamed.displayName = move.toValue
        renamed.remoteId = newRemoteId ?? folder.remoteId
        try RemoteFolderRepository.save(db, renamed)
        if let old = folder.remoteId, let new = newRemoteId {
            try OrganizationQueries.rebasePaths(db, destinationId: folder.destinationId, from: old, to: new)
        }
        if let id = move.id { try MoveJobRepository.complete(db, id: id) }
    }
}

/// Step 8 of the cycle: `move_job`s, pending → inProgress (persisted) → destination effect →
/// commit → done; more than 8 failures end in `failed`. Folder creation goes through the same
/// per-destination ensurer as uploads, so reserved ids are persisted before any create.
actor MoveWorker {
    private enum Outcome { case done, retry, stop }

    /// What a finished operation changed that the owner can see.
    private enum Change { case none, renamed(from: String, to: String), moved(into: String) }

    private let env: EngineEnvironment
    private let uploader: UploadRunner

    init(env: EngineEnvironment, uploader: UploadRunner) {
        self.env = env
        self.uploader = uploader
    }

    /// Runs the pending moves of every destination; returns how many finished.
    func runPass() async throws -> Int {
        let ids = await env.destinations.ids
        var total = 0
        try await withThrowingTaskGroup(of: Int.self) { group in
            for id in ids { group.addTask { try await self.runDestination(id) } }
            for try await count in group { total += count }
        }
        return total
    }

    private func runDestination(_ id: DestinationID) async throws -> Int {
        guard let record = try await env.store.read({ db in try DestinationRepository.fetch(db, id: id) }), record.acceptsUploads,
              let destination = await env.destinations.destination(for: id) else { return 0 }
        let pending = try await env.store.read { db in try MoveJobRepository.fetch(db, destinationId: id, state: .pending) }
        let ensurer = await uploader.ensurer(for: record, destination: destination)
        var finished = 0
        var activity = MovePassActivity()
        do {
            passLoop: for move in pending {
                try Task.checkCancellation()
                var change = Change.none
                switch try await execute(move, record: record, destination: destination, ensurer: ensurer, change: &change) {
                case .done:
                    finished += 1
                    switch change {
                    case .none: break
                    case .renamed(let from, let to): activity.renamed(from: from, to: to)
                    case .moved(let folder): activity.moved(into: folder)
                    }
                case .retry: continue
                case .stop: break passLoop
                }
            }
        } catch {
            // What finished before the error did happen at the destination.
            await ActivityLog(env: env).record(activity.events(), destination: id)
            throw error
        }
        await ActivityLog(env: env).record(activity.events(), destination: id)
        return finished
    }

    private func execute(_ move: MoveJob, record: DestinationRecord, destination: any Destination, ensurer: FolderEnsurer,
                         change: inout Change) async throws -> Outcome {
        guard let id = move.id, try await env.store.write({ db in try MoveJobRepository.start(db, id: id) }) else { return .retry }
        do {
            switch move.operation {
            case .moveFile: change = try await moveFile(move, record: record, destination: destination, ensurer: ensurer)
            case .renameFolder: change = try await renameFolder(move, record: record, destination: destination)
            }
            return .done
        } catch {
            if error is EngineAbort || error is CancellationError { throw error }
            return try await fail(move, error: error, ensurer: ensurer)
        }
    }

    // MARK: Operations

    private func moveFile(_ move: MoveJob, record: DestinationRecord, destination: any Destination, ensurer: FolderEnsurer) async throws -> Change {
        let env = env
        let layout = env.layout
        guard let identity = JobIdentity(subject: move.subject, destinationId: record.id) else { try await discard(move); return .none }
        let loaded: (job: UploadJob, chain: [FolderLevel])? = try await env.store.read { db in
            guard let job = try JobRepository.fetch(db, identity: identity), let asset = try AssetRepository.fetch(db, key: identity.assetKey),
                  let placement = asset.placement else { return nil }
            return (job, try LayoutResolver.chain(db, placement: placement, layout: layout))
        }
        // A job that lost its file (re-upload, narrowing) has nothing to move.
        guard let loaded, let remoteId = loaded.job.remoteId, let name = loaded.job.remoteName,
              ![JobState.cancelled, .missingRemote].contains(loaded.job.state) else { try await discard(move); return .none }
        let target = LayoutResolver.parentLogical(loaded.chain)
        let from = loaded.job.remoteLogicalParent ?? move.fromValue
        guard from != target else { try await discard(move); return .none }
        let toRef = try await ensurer.ensure(loaded.chain)
        let rootId = FolderRefResolver.rootId(record)
        let fromRef = try await env.store.read { db in
            try FolderRefResolver.ref(db, destinationId: record.id, logicalPath: from, rootId: rootId)
        }
        let item = try await destination.move(remoteId: remoteId, name: name, from: fromRef, to: toRef)
        try await env.store.write { db in try MoveCommit.file(db, move: move, identity: identity, parent: target, remoteId: item.remoteId) }
        env.log.log(.info, category: "move", "moved file job=\(identity.resType.rawValue) dest=\(record.id)")
        return loaded.chain.last.map { .moved(into: $0.displayName) } ?? .none
    }

    private func renameFolder(_ move: MoveJob, record: DestinationRecord, destination: any Destination) async throws -> Change {
        let env = env
        let id = record.id
        let path = move.subject
        let rootId = FolderRefResolver.rootId(record)
        guard let folder = try await env.store.read({ db in try RemoteFolderRepository.fetch(db, destinationId: id, logicalPath: path) })
        else { try await discard(move); return .none }
        guard folder.created, folder.remoteId != nil else {
            // Not created yet: it will be created under its new name, so the owner sees no rename.
            try await env.store.write { db in try MoveCommit.rename(db, move: move, folder: folder, newRemoteId: nil) }
            return .none
        }
        let ref = try await env.store.read { db in try FolderRefResolver.ref(db, destinationId: id, logicalPath: path, rootId: rootId) }
        let renamed = try await destination.renameFolder(ref, newName: move.toValue)
        try await env.store.write { db in try MoveCommit.rename(db, move: move, folder: folder, newRemoteId: renamed.remoteId) }
        env.log.log(.info, category: "move", "renamed folder dest=\(id)")
        return .renamed(from: folder.displayName, to: move.toValue)
    }

    private func discard(_ move: MoveJob) async throws {
        guard let id = move.id else { return }
        try await env.store.write { db in _ = try MoveJobRepository.complete(db, id: id) }
    }

    // MARK: Failures

    private func fail(_ move: MoveJob, error: any Error, ensurer: FolderEnsurer) async throws -> Outcome {
        guard let id = move.id else { return .retry }
        let failure = error as? DestinationError
        if let failure, case .destinationLevel(let status) = ErrorClassifier.classify(failure) {
            let destinationId = move.destinationId
            let now = env.clock.now
            try await env.store.write { db in
                try OrganizationQueries.requeueMove(db, id: id)
                if let status { try DestinationRepository.setStatus(db, id: destinationId, status: status, now: now) }
            }
            return .stop
        }
        if case .folderMissing(let path)? = failure { try await ensurer.invalidate(logicalPath: path) }
        let message = failure.map(\.description) ?? "unexpected error"
        env.log.log(.notice, category: "move", "move failed op=\(move.operation.rawValue) error=\(message)")
        try await env.store.write { db in _ = try MoveJobRepository.fail(db, id: id, message: message) }
        return .retry
    }
}
