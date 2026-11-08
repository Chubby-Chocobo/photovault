import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Startup recovery of moves that were `inProgress` when the process died (spec 8.3, 8.9.4). The
/// destination is asked where the item is now: already moved or renamed → commit; not yet → back to
/// `pending`; a folder under neither name → `failed` plus an owner notice (integrity check).
/// Every destination operation is idempotent, so a probe that cannot be answered also just retries.
struct MoveRecovery: RecoveryParticipant {
    let env: EngineEnvironment

    func recover() async throws {
        for record in try await env.store.read({ db in try DestinationRepository.fetchAll(db) }) {
            let id = record.id
            let interrupted = try await env.store.read { db in try MoveJobRepository.fetch(db, destinationId: id, state: .inProgress) }
            guard !interrupted.isEmpty else { continue }
            let destination = await env.destinations.destination(for: id)
            for move in interrupted {
                guard let moveId = move.id else { continue }
                guard let destination else {
                    try await requeue(moveId)
                    continue
                }
                do {
                    switch move.operation {
                    case .moveFile: try await resolveFile(move, record: record, destination: destination)
                    case .renameFolder: try await resolveRename(move, record: record, destination: destination)
                    }
                } catch {
                    if error is EngineAbort || error is CancellationError { throw error }
                    env.log.log(.notice, category: "recovery", "move probe failed; will retry")
                    try await requeue(moveId)
                }
            }
        }
    }

    private func requeue(_ id: Int64) async throws {
        try await env.store.write { db in try OrganizationQueries.requeueMove(db, id: id) }
    }

    private func resolveFile(_ move: MoveJob, record: DestinationRecord, destination: any Destination) async throws {
        let env = env
        let layout = env.layout
        guard let moveId = move.id, let identity = JobIdentity(subject: move.subject, destinationId: record.id) else { return }
        let state: (job: UploadJob, target: String, folder: RemoteFolder?)? = try await env.store.read { db in
            guard let job = try JobRepository.fetch(db, identity: identity), let asset = try AssetRepository.fetch(db, key: identity.assetKey),
                  let placement = asset.placement else { return nil }
            let target = LayoutResolver.parentLogical(try LayoutResolver.chain(db, placement: placement, layout: layout))
            return (job, target, try RemoteFolderRepository.fetch(db, destinationId: record.id, logicalPath: target))
        }
        guard let state, let remoteId = state.job.remoteId, let name = state.job.remoteName else {
            try await env.store.write { db in _ = try MoveJobRepository.complete(db, id: moveId) }
            return
        }
        var found = try await destination.probe(remoteId: remoteId)
        if found == nil, let folderId = state.folder?.remoteId, !destination.capabilities.reservesIds {
            // Path-addressed destinations: the file is under its new path when the move happened.
            found = try await destination.probe(remoteId: folderId.isEmpty ? name : folderId + "/" + name)
        }
        guard let item = found, !item.trashed, let folderId = state.folder?.remoteId,
              item.parentIds.contains(folderId) || item.relativePath.map({ $0.hasPrefix(folderId + "/") }) == true else {
            try await requeue(moveId)
            return
        }
        try await env.store.write { db in
            try MoveCommit.file(db, move: move, identity: identity, parent: state.target, remoteId: item.remoteId)
        }
    }

    private func resolveRename(_ move: MoveJob, record: DestinationRecord, destination: any Destination) async throws {
        let env = env
        guard let moveId = move.id,
              let folder = try await env.store.read({ db in
                  try RemoteFolderRepository.fetch(db, destinationId: record.id, logicalPath: move.subject)
              }), let oldId = folder.remoteId else {
            if let moveId = move.id { try await env.store.write { db in _ = try MoveJobRepository.complete(db, id: moveId) } }
            return
        }
        if let item = try await destination.probe(remoteId: oldId), !item.trashed {
            if item.name == move.toValue {
                try await env.store.write { db in try MoveCommit.rename(db, move: move, folder: folder, newRemoteId: item.remoteId) }
            } else {
                try await requeue(moveId)
            }
            return
        }
        // Path-addressed: the old path is gone, so the rename either happened or the folder vanished.
        let parentPath = oldId.contains("/") ? String(oldId[..<oldId.lastIndex(of: "/")!]) + "/" : ""
        if !destination.capabilities.reservesIds, let renamed = try await destination.probe(remoteId: parentPath + move.toValue) {
            try await env.store.write { db in try MoveCommit.rename(db, move: move, folder: folder, newRemoteId: renamed.remoteId) }
            return
        }
        try await env.store.write { db in try OrganizationQueries.failMove(db, id: moveId, message: "folder missing under both names") }
        await ActivityLog(env: env).record(.notice, destination: record.id, "Thư mục đổi tên dở dang không còn dưới tên cũ hay mới; cần kiểm tra toàn vẹn")
    }
}
