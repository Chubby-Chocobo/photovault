import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Creates the folder chain of a destination (spec 8.4 step 6). One instance per destination, so
/// two uploads that need the same folder never create it twice. For destinations that reserve ids
/// (Drive) the id is persisted in `remote_folder` before the create call; after a crash the same
/// id is used again and an `alreadyExists` answer is verified with a probe (FR-47).
actor FolderEnsurer {
    private let env: EngineEnvironment
    private let destination: any Destination
    private let destinationId: DestinationID
    private let root: RemoteFolderRef
    private var inFlight: [String: Task<RemoteFolderRef, any Error>] = [:]

    init(env: EngineEnvironment, destination: any Destination, record: DestinationRecord) {
        self.env = env
        self.destination = destination
        destinationId = record.id
        root = .root(remoteId: record.config.driveRootId ?? "")
    }

    /// Ensures every level and returns the deepest folder (the root for an empty chain).
    func ensure(_ chain: [FolderLevel]) async throws -> RemoteFolderRef {
        var parent = root
        for level in chain { parent = try await ensureLevel(level, parent: parent) }
        return parent
    }

    private func ensureLevel(_ level: FolderLevel, parent: RemoteFolderRef) async throws -> RemoteFolderRef {
        if let running = inFlight[level.logicalPath] { return try await running.value }
        let task = Task { try await self.createLevel(level, parent: parent) }
        inFlight[level.logicalPath] = task
        defer { inFlight[level.logicalPath] = nil }
        return try await task.value
    }

    private func createLevel(_ level: FolderLevel, parent: RemoteFolderRef) async throws -> RemoteFolderRef {
        let id = destinationId
        let path = level.logicalPath
        let row = try await env.store.read { db in try RemoteFolderRepository.fetch(db, destinationId: id, logicalPath: path) }
        if let row, row.created, let remoteId = row.remoteId {
            return RemoteFolderRef(logicalPath: path, remoteId: remoteId, displayPath: Self.displayPath(parent, row.displayName))
        }
        var reserved: String?
        if destination.capabilities.reservesIds {
            if let existing = row?.remoteId {
                reserved = existing
            } else {
                guard let fresh = try await destination.reserveIds(count: 1, kind: .files).first else {
                    throw DestinationError.itemRejected(reason: "no folder id reserved")
                }
                try await save(RemoteFolder(destinationId: id, logicalPath: path, remoteId: fresh, displayName: level.displayName, created: false))
                reserved = fresh
            }
            try env.reach(.afterFolderIdPersisted)
        }
        let request = FolderRequest(
            logicalPath: path, name: level.displayName, parent: parent, reservedId: reserved,
            appProperties: AppPropertyCodec.folderProperties(logicalPath: path, view: nil))
        let ref: RemoteFolderRef
        do {
            ref = try await destination.ensureFolder(request)
        } catch DestinationError.alreadyExists(let existingId) {
            ref = try await confirmExisting(existingId.isEmpty ? reserved : existingId, level: level, parent: parent)
        }
        try env.reach(.afterFolderCreated)
        try await save(RemoteFolder(destinationId: id, logicalPath: path, remoteId: ref.remoteId, displayName: level.displayName, created: true))
        return ref
    }

    /// `alreadyExists` after a crash or retry: accept the folder only if it is ours, in the right
    /// parent and not trashed.
    private func confirmExisting(_ remoteId: String?, level: FolderLevel, parent: RemoteFolderRef) async throws -> RemoteFolderRef {
        guard let remoteId, let item = try await destination.probe(remoteId: remoteId) else {
            throw DestinationError.folderMissing(logicalPath: level.logicalPath)
        }
        if item.trashed { throw DestinationError.folderTrashed(logicalPath: level.logicalPath) }
        guard item.kind == .folder, item.parentIds.contains(parent.remoteId) else {
            throw DestinationError.itemRejected(reason: "reserved folder id in use")
        }
        return RemoteFolderRef(logicalPath: level.logicalPath, remoteId: item.remoteId, displayPath: Self.displayPath(parent, level.displayName))
    }

    /// Forgets the creation state of `logicalPath` and everything below it (FR-47 folder gone); the
    /// next ensure reserves new ids.
    func invalidate(logicalPath: String) async throws {
        let id = destinationId
        try await env.store.write { db in
            for folder in try RemoteFolderRepository.fetchAll(db, destinationId: id)
            where folder.logicalPath == logicalPath || folder.logicalPath.hasPrefix(logicalPath + "/") {
                var reset = folder
                reset.remoteId = nil
                reset.created = false
                try RemoteFolderRepository.save(db, reset)
            }
        }
    }

    private func save(_ folder: RemoteFolder) async throws {
        try await env.store.write { db in try RemoteFolderRepository.save(db, folder) }
    }

    private static func displayPath(_ parent: RemoteFolderRef, _ name: String) -> String {
        parent.displayPath.isEmpty ? name : parent.displayPath + "/" + name
    }
}
