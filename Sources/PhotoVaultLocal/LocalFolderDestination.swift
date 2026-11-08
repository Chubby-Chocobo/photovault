import Foundation
import PhotoVaultCore

/// Backup destination on a local, external or network folder (spec 4.9, 8.9.4). Writes are atomic and
/// never overwrite; nothing but temp `.part` and `.photovault-test` files is ever deleted.
public actor LocalFolderDestination: Destination {
    public nonisolated let id: DestinationID
    public nonisolated let capabilities = DestinationCapabilities(
        supportsViews: false, supportsAppProperties: false, supportsQuota: true,
        supportsDescription: false, reservesIds: false, verifiedHash: .sha256)

    private let ops: LocalFileOps
    private let access: any RootAccess
    private let locks = FolderLockManager()
    private let disk: (any DiskSpaceProvider)?
    private let log: any LogSink

    public init(id: DestinationID, root: any RootAccess, disk: (any DiskSpaceProvider)? = nil, log: any LogSink = NullLogSink()) {
        self.id = id
        self.access = root
        self.disk = disk
        self.log = log
        self.ops = LocalFileOps(access: root, writer: AtomicFileWriter(), log: log)
    }

    /// Runs file work under the folder read lock; when the filesystem lacks an exclusive rename, repeats
    /// it under the write lock with the check-then-rename fallback enabled.
    private func placing<T: Sendable>(_ path: String, _ body: @escaping @Sendable (Bool) throws -> T) async throws -> T {
        do {
            return try await locks.withLock(path, write: false) { try body(false) }
        } catch is ExclusiveRenameUnsupported {
            log.log(.notice, category: "local", "exclusive rename unsupported, using locked check-then-rename")
            return try await locks.withLock(path, write: true) { try body(true) }
        }
    }

    // MARK: Availability

    public func checkAvailability() async -> DestinationStatus {
        let ops = self.ops
        do {
            try await Task.detached { try ops.checkRootAndSweep() }.value
            return .active
        } catch let error as DestinationError {
            return Self.status(for: error)
        } catch {
            return .unavailable(.offline)
        }
    }

    static func status(for error: DestinationError) -> DestinationStatus {
        if case .destinationLevel(let status?) = ErrorClassifier.classify(error) { return status }
        // A symlinked `.photovault` or tmp folder is unsafe to write through: stop until the owner looks.
        if case .itemRejected = error { return .paused(.rootMissing) }
        return .unavailable(.offline)
    }

    /// Writes, reads back and deletes `.photovault-test` (FR-70).
    public func testConnection() async throws {
        let ops = self.ops
        try await Task.detached { try ops.testConnection() }.value
    }

    // MARK: destination.json

    public func readMarker() async throws -> DestinationMarker? {
        let ops = self.ops
        return try await Task.detached { try ops.readMarker() }.value
    }

    /// Never overwrites: an existing marker with the same id is returned, another id throws `foreignFile`.
    public func writeMarker(_ marker: DestinationMarker) async throws -> DestinationMarker {
        let ops = self.ops
        return try await placing(LocalPath.reservedDirectory) { try ops.writeMarker(marker, allowFallback: $0) }
    }

    // MARK: Destination

    public func reserveIds(count: Int, kind: ReservedIdKind) async throws -> [String] {
        (0..<max(0, count)).map { _ in UUID().uuidString }
    }

    public func ensureFolder(_ request: FolderRequest) async throws -> RemoteFolderRef {
        let ops = self.ops
        return try await locks.withLock(request.parent.remoteId, write: false) { try ops.ensureFolder(request) }
    }

    public func upload(_ request: UploadRequest, onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        let ops = self.ops
        return try await placing(request.parent.remoteId) { try ops.upload(request, allowFallback: $0) }
    }

    /// Local writes have no sessions.
    public func resumeUpload(_ request: UploadRequest, session: SessionCheckpoint,
                             onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        throw DestinationError.sessionExpired
    }

    public func probe(remoteId: String) async throws -> RemoteItem? {
        let ops = self.ops
        return try await Task.detached { try ops.probe(remoteId) }.value
    }

    /// SHA-256 of the file at `remoteId` (a relative path), nil when absent.
    public func contentHash(remoteId: String) async throws -> String? {
        let ops = self.ops
        return try await Task.detached { try ops.contentHash(remoteId) }.value
    }

    public func replaceContent(remoteId: String, _ request: UploadRequest) async throws -> UploadResult {
        let ops = self.ops
        let (parent, _) = try LocalPath.split(remoteId)
        return try await locks.withLock(parent, write: true) { try ops.replace(path: remoteId, request) }
    }

    public func move(remoteId: String, name: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem {
        let ops = self.ops
        let (sourceParent, _) = try LocalPath.split(remoteId)
        // One lock on the common ancestor avoids lock-order deadlocks between the two folders.
        let ancestor = LocalPath.commonAncestor(sourceParent, to.remoteId)
        return try await placing(ancestor) { try ops.move(path: remoteId, name: name, to: to, allowFallback: $0) }
    }

    public func renameFolder(_ folder: RemoteFolderRef, newName: String) async throws -> RemoteFolderRef {
        let ops = self.ops
        return try await locks.withLock(folder.remoteId, write: true) { try ops.renameFolder(folder, newName: newName) }
    }

    public nonisolated func list(under folder: RemoteFolderRef?) -> AsyncThrowingStream<RemoteItem, any Error> {
        let ops = self.ops
        let start = folder?.remoteId ?? ""
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try ops.walk(under: start) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func quota() async throws -> Quota? {
        let disk = self.disk
        return try access.withRoot { url -> Quota in
            if let disk {
                let capacity = try disk.capacity(of: url)
                return Quota(totalBytes: capacity.total, usedBytes: capacity.total - capacity.available, availableBytes: capacity.available)
            }
            do {
                let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
                guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity else { return Quota(totalBytes: nil, usedBytes: nil, availableBytes: nil) }
                return Quota(totalBytes: Int64(total), usedBytes: Int64(total - free), availableBytes: Int64(free))
            } catch {
                throw DestinationError.offline
            }
        }
    }

    // MARK: Maintenance

    /// Compares the expected files with the disk and re-hashes the deterministic sample (FR-76).
    public func verifyIntegrity(expected: [ExpectedFile], seed: String) async throws -> IntegrityReport {
        let ops = self.ops
        return try await Task.detached { try ops.verifyIntegrity(expected: expected, seed: seed) }.value
    }

    /// Startup decision for a folder rename left `inProgress` (spec 8.9.4).
    public func recoverRename(oldPath: String, newPath: String) async throws -> RenameRecoveryDecision {
        let ops = self.ops
        return try await Task.detached { try ops.renameRecovery(oldPath: oldPath, newPath: newPath) }.value
    }
}
