import Foundation
import PhotoVaultCore

/// Google Drive backup destination (`drive.file` scope). Never deletes anything; never recreates a
/// missing or trashed root (FR-47).
public actor GoogleDriveDestination: ViewDestination, RootManaging {
    public nonisolated let id: DestinationID
    public nonisolated let capabilities = DestinationCapabilities(
        supportsViews: true, supportsAppProperties: true, supportsQuota: true,
        supportsDescription: true, reservesIds: true, verifiedHash: .md5)

    nonisolated let api: DriveAPI
    let uploader: ResumableUploader
    let clock: any Clock
    let log: any LogSink
    private(set) var rootId: String?
    private var cap: DailyUploadCap
    private let onDailyCapChange: (@Sendable (DailyCapState) -> Void)?

    /// - Parameters:
    ///   - dailyCapState: persisted cap entries to restore at launch (FR-49).
    ///   - onDailyCapChange: called synchronously on every reserve/release with the state to persist; keep it fast.
    ///   - writeLimiter: shared token bucket for write calls; nil disables limiting.
    public init(id: DestinationID = .googleDrive, transport: any HTTPTransport, auth: any DriveAuthorizing,
                rootId: String? = nil, cap: DailyUploadCap = DailyUploadCap(),
                dailyCapState: DailyCapState? = nil, onDailyCapChange: (@Sendable (DailyCapState) -> Void)? = nil,
                writeLimiter: DriveWriteLimiter? = DriveWriteLimiter.standard(),
                chunkSize: Int = 8 * 1024 * 1024,
                clock: any Clock = SystemClock(), log: any LogSink = NullLogSink()) {
        let api = DriveAPI(transport: transport, auth: auth, writeLimiter: writeLimiter)
        self.id = id
        self.api = api
        self.uploader = ResumableUploader(http: api.http, chunkSize: chunkSize, writeLimiter: writeLimiter)
        self.rootId = rootId
        self.cap = dailyCapState.map { DailyUploadCap(limit: cap.limit, state: $0) } ?? cap
        self.onDailyCapChange = onDailyCapChange
        self.clock = clock
        self.log = log
    }

    public func setRootId(_ remoteId: String?) { rootId = remoteId }
    public func currentRootId() -> String? { rootId }

    /// Bytes uploaded in the last 24 hours by this process.
    public func dailyUsage() -> Int64 { cap.usage(at: clock.now) }

    /// Snapshot for the engine to persist.
    public func dailyCapState() -> DailyCapState { cap.state }

    // MARK: Availability and IDs

    public func checkAvailability() async -> DestinationStatus {
        guard let rootId else { return .paused(.rootMissing) }
        do {
            switch try await checkRoot(remoteId: rootId) {
            case .ok: return .active
            case .missing: return .paused(.rootMissing)
            case .trashed: return .paused(.rootTrashed)
            }
        } catch let error as DestinationError {
            if case .destinationLevel(let status?) = ErrorClassifier.classify(error) { return status }
            return .unavailable(.offline)
        } catch {
            return .unavailable(.offline)
        }
    }

    public func reserveIds(count: Int, kind: ReservedIdKind) async throws -> [String] {
        guard count > 0 else { return [] }
        return try await api.generateIds(count: count, kind: kind)
    }

    // MARK: Folders

    public func ensureFolder(_ request: FolderRequest) async throws -> RemoteFolderRef {
        guard let reserved = request.reservedId else { throw DestinationError.itemRejected(reason: "id not reserved") }
        let write = DriveFileWrite(id: reserved, name: request.name, mimeType: DriveMime.folder,
                                   parents: [request.parent.remoteId],
                                   appProperties: try Self.prepared(request.appProperties))
        let file = try await createVerified(write, name: request.name, mimeType: DriveMime.folder, parent: request.parent)
        let display = request.parent.displayPath.isEmpty ? request.name : request.parent.displayPath + "/" + request.name
        return RemoteFolderRef(logicalPath: request.logicalPath, remoteId: file.id, displayPath: display)
    }

    public func renameFolder(_ folder: RemoteFolderRef, newName: String) async throws -> RemoteFolderRef {
        _ = try await api.update(folder.remoteId, DriveFileWrite(name: newName))
        var components = folder.displayPath.split(separator: "/").map(String.init)
        if components.isEmpty { components = [newName] } else { components[components.count - 1] = newName }
        return RemoteFolderRef(logicalPath: folder.logicalPath, remoteId: folder.remoteId, displayPath: components.joined(separator: "/"))
    }

    // MARK: Files

    public func upload(_ request: UploadRequest, onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        guard let reserved = request.reservedRemoteId else { throw DestinationError.itemRejected(reason: "id not reserved") }
        let reservation = try reserveCap(request.content.size)
        let write = DriveFileWrite(id: reserved, name: request.fileName, parents: [request.parent.remoteId],
                                   appProperties: try Self.prepared(request.appProperties), description: request.description)
        let file: DriveFile
        do {
            file = try await uploader.upload(.create(write), file: request.content.file, size: request.content.size,
                                             md5: request.content.md5, progress: request.progress, onSession: onSession)
        } catch {
            releaseCap(reservation)
            // Only the session-start request can mean "parent missing"; transfer errors never reach here as notFound.
            if case DestinationError.notFound = error { throw parentMissing(request.parent) }
            throw error
        }
        return try finish(file, request, parent: request.parent)
    }

    public func resumeUpload(_ request: UploadRequest, session: SessionCheckpoint,
                             onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        // The persisted session belongs to other bytes (re-export differs, file changed): never resume it.
        guard session.md5 == request.content.md5, session.totalBytes == request.content.size else {
            throw DestinationError.sessionExpired
        }
        let reservation = try reserveCap(request.content.size)
        let file: DriveFile
        do {
            file = try await uploader.resume(sessionRef: session.sessionRef, file: request.content.file, size: request.content.size, progress: request.progress)
        } catch {
            releaseCap(reservation)
            throw error
        }
        return try finish(file, request, parent: request.parent)
    }

    public func probe(remoteId: String) async throws -> RemoteItem? {
        do { return try await api.get(remoteId).remoteItem } catch DestinationError.notFound { return nil }
    }

    public func replaceContent(remoteId: String, _ request: UploadRequest) async throws -> UploadResult {
        let reservation = try reserveCap(request.content.size)
        let file: DriveFile
        do {
            file = try await uploader.upload(.update(id: remoteId), file: request.content.file, size: request.content.size,
                                             md5: request.content.md5, progress: request.progress, onSession: { _ in })
        } catch {
            releaseCap(reservation)
            throw error
        }
        return try finish(file, request, parent: nil)
    }

    public func move(remoteId: String, name: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem {
        let file = try await api.update(remoteId, DriveFileWrite(name: name), addParents: [to.remoteId], removeParents: [from.remoteId])
        if file.trashed == true { throw trashedError(to) }
        return file.remoteItem
    }

    /// Trashed items are listed too, with `trashed` set (Drive also sets it on everything inside a
    /// trashed folder): finding trashed app folders and telling an owner's trash from a trashed
    /// ancestor depend on seeing them. With a folder, only its direct children are listed.
    public nonisolated func list(under folder: RemoteFolderRef?) -> AsyncThrowingStream<RemoteItem, any Error> {
        var query = DriveQuery.all.appCreated
        if let folder { query = query.parent(folder.remoteId) }
        return stream(query)
    }

    public func quota() async throws -> Quota? { try await api.quota() }

    // MARK: Shared helpers

    nonisolated func stream(_ query: DriveQuery) -> AsyncThrowingStream<RemoteItem, any Error> {
        let api = api
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var token: String?
                    repeat {
                        let page = try await api.listPage(query, pageToken: token)
                        for file in page.files { continuation.yield(file.remoteItem) }
                        token = page.nextPageToken
                    } while token != nil
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every app-created item carries `pvSchema` so `list` finds it; Drive caps a key+value pair at 124 bytes.
    static func prepared(_ properties: [String: String]) throws -> [String: String] {
        var result = properties
        if result[AppPropertyKey.schema] == nil { result[AppPropertyKey.schema] = AppPropertyCodec.schemaVersion }
        for (key, value) in result where key.utf8.count + value.utf8.count > AppPropertyCodec.maxPairBytes {
            throw DestinationError.itemRejected(reason: "appProperties pair too long")
        }
        return result
    }

    func trashedError(_ parent: RemoteFolderRef) -> DestinationError {
        parent.remoteId == rootId ? .rootTrashed : .folderTrashed(logicalPath: parent.logicalPath)
    }

    func parentMissing(_ parent: RemoteFolderRef) -> DestinationError {
        parent.remoteId == rootId ? .rootMissing : .folderMissing(logicalPath: parent.logicalPath)
    }

    private struct CapReservation { var bytes: Int64; var at: Date }

    /// Counts the bytes before the first request so parallel uploads cannot overshoot the limit.
    private func reserveCap(_ bytes: Int64) throws -> CapReservation {
        let now = clock.now
        guard cap.reserve(bytes: bytes, at: now) else { throw DestinationError.dailyCapReached }
        onDailyCapChange?(cap.state)
        return CapReservation(bytes: bytes, at: now)
    }

    /// An upload that failed before completing did not consume the day's budget.
    private func releaseCap(_ reservation: CapReservation) {
        cap.release(bytes: reservation.bytes, at: reservation.at)
        onDailyCapChange?(cap.state)
    }

    private func finish(_ file: DriveFile, _ request: UploadRequest, parent: RemoteFolderRef?) throws -> UploadResult {
        if file.trashed == true, let parent { throw trashedError(parent) }
        if let parent, file.parents?.contains(parent.remoteId) != true { throw parentMissing(parent) }
        let actual = file.md5Checksum ?? ""
        guard actual == request.content.md5 else {
            throw DestinationError.checksumMismatch(expected: request.content.md5, actual: actual)
        }
        return UploadResult(remoteId: file.id, finalName: file.name ?? request.fileName, verifiedHash: actual,
                            parentIds: file.parents ?? [], trashed: file.trashed ?? false,
                            size: file.size.flatMap { Int64($0) } ?? request.content.size)
    }

    /// Creates a metadata item. A 409 is resolved by fetching the item and comparing; anything that
    /// differs from what we meant to create throws `alreadyExists` rather than being assumed OK.
    func createVerified(_ write: DriveFileWrite, name: String, mimeType: String, parent: RemoteFolderRef?,
                        targetId: String? = nil) async throws -> DriveFile {
        let file: DriveFile
        do {
            file = try await api.create(write)
        } catch DestinationError.notFound {
            throw parent.map(parentMissing) ?? DestinationError.notFound
        } catch DestinationError.alreadyExists {
            let id = write.id ?? ""
            let existing: DriveFile
            do { existing = try await api.get(id) } catch DestinationError.notFound { throw DestinationError.alreadyExists(remoteId: id) }
            let sameParent = parent.map { existing.parents?.contains($0.remoteId) == true } ?? true
            guard existing.name == name, existing.mimeType == mimeType, sameParent,
                  targetId == nil || existing.shortcutDetails?.targetId == targetId else {
                throw DestinationError.alreadyExists(remoteId: id)
            }
            file = existing
        }
        if file.trashed == true, let parent { throw trashedError(parent) }
        return file
    }
}
