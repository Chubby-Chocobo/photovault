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
    /// Serial: copies, fsyncs, hashes and renames, one at a time.
    private let queue: BlockingQueue
    /// Concurrent: probes, health checks, marker and small-file reads never wait behind a copy.
    private let metadataQueue: BlockingQueue
    private let disk: (any DiskSpaceProvider)?
    private let log: any LogSink

    public init(id: DestinationID, root: any RootAccess, disk: (any DiskSpaceProvider)? = nil, log: any LogSink = NullLogSink()) {
        self.init(id: id, root: root, disk: disk, log: log, renameMemo: .volumes)
    }

    init(id: DestinationID, root: any RootAccess, disk: (any DiskSpaceProvider)? = nil, log: any LogSink = NullLogSink(),
         renameMemo: ExclusiveRenameMemo, afterStaging: (@Sendable () -> Void)? = nil,
         onDirectorySync: (@Sendable (String) -> Void)? = nil) {
        self.id = id
        self.metadataQueue = BlockingQueue(label: "photovault.local.meta.\(id.rawValue)", concurrent: true)
        self.queue = BlockingQueue(label: "photovault.local.\(id.rawValue)")
        self.access = root
        self.disk = disk
        self.log = log
        self.ops = LocalFileOps(access: root, writer: AtomicFileWriter(), log: log, renameMemo: renameMemo, afterStaging: afterStaging,
                          onDirectorySync: onDirectorySync)
    }

    /// Runs file work under the folder read lock; when the filesystem lacks an exclusive rename, repeats
    /// it under the write lock with the check-then-rename fallback enabled.
    private func placing<T: Sendable>(_ path: String, _ body: @escaping @Sendable (Bool) throws -> T) async throws -> T {
        do {
            return try await locks.withLock(path, write: false, on: queue) { try body(false) }
        } catch is ExclusiveRenameUnsupported {
            log.log(.notice, category: "local", "exclusive rename unsupported, using locked check-then-rename")
            return try await locks.withLock(path, write: true, on: queue) { try body(true) }
        }
    }

    // MARK: Availability

    public func checkAvailability() async -> DestinationStatus {
        let ops = self.ops
        do {
            try await metadataQueue.run { try ops.checkRootAndSweep() }
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
        try await metadataQueue.run { try ops.testConnection() }
    }

    // MARK: destination.json

    public func readMarker() async throws -> DestinationMarker? {
        let ops = self.ops
        return try await metadataQueue.run { try ops.readMarker() }
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
        return try await locks.withLock(request.parent.remoteId, write: false, on: metadataQueue) { try ops.ensureFolder(request) }
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
        return try await metadataQueue.run { try ops.probe(remoteId) }
    }

    /// SHA-256 of the file at `remoteId` (a relative path), nil when absent.
    public func contentHash(remoteId: String) async throws -> String? {
        let ops = self.ops
        return try await queue.run { try ops.contentHash(remoteId) }
    }

    /// Bytes of a small file (a sidecar) at `remoteId`, nil when absent; larger than `maxBytes` throws.
    public func readSmallFile(remoteId: String, maxBytes: Int = 1 << 20) async throws -> Data? {
        let ops = self.ops
        return try await metadataQueue.run { try ops.readSmallFile(remoteId, maxBytes: maxBytes) }
    }

    public func replaceContent(remoteId: String, _ request: UploadRequest) async throws -> UploadResult {
        let ops = self.ops
        let (parent, _) = try LocalPath.split(remoteId)
        return try await locks.withLock(parent, write: true, on: queue) { try ops.replace(path: remoteId, request) }
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
        return try await locks.withLock(folder.remoteId, write: true, on: queue) { try ops.renameFolder(folder, newName: newName) }
    }

    /// Names of the folders directly inside `path` (empty = the root), without descending.
    public func childFolderNames(under path: String) async throws -> [String] {
        let ops = self.ops
        return try await metadataQueue.run { try ops.childFolderNames(under: path) }
    }

    /// The walk runs on the metadata queue, never on the Swift concurrency pool; ending the stream stops it.
    public nonisolated func list(under folder: RemoteFolderRef?) -> AsyncThrowingStream<RemoteItem, any Error> {
        let ops = self.ops
        let start = folder?.remoteId ?? ""
        let queue = self.metadataQueue
        return AsyncThrowingStream { continuation in
            let cancelled = CancellationFlag()
            queue.submit {
                do {
                    try ops.walk(under: start, isCancelled: { cancelled.isSet }) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in cancelled.set() }
        }
    }

    public func quota() async throws -> Quota? {
        let disk = self.disk
        let access = self.access
        return try await metadataQueue.run { try Self.quota(access: access, disk: disk) }
    }

    private static func quota(access: any RootAccess, disk: (any DiskSpaceProvider)?) throws -> Quota {
        try access.withRoot { url -> Quota in
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
}

/// Set when the consumer of a listing stops; read by the walk on its queue.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
