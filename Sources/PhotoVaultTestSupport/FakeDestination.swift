import Foundation
import PhotoVaultCore

/// In-memory destination. With `reservesIds` it behaves like Drive (IDs must be reserved first,
/// duplicate IDs are rejected); without, like a local folder (files identified by path, same name
/// + same hash is success, different content gets a conflict name or `foreignFile`).
public actor FakeDestination: ViewDestination, RootManaging {
    public enum Operation: String, Hashable, Sendable {
        case reserve, ensureFolder, upload, resume, probe, replace, move, rename, list, shortcut, availability
    }

    /// Simulates a crash after the remote side effect but before the caller sees the result.
    public struct CrashAfterEffect: Error, Hashable {}

    public struct Item: Hashable, Sendable {
        public var id: String
        public var name: String
        public var parentId: String
        public var kind: RemoteItemKind
        public var content: StagedContent?
        public var appProperties: [String: String]
        public var description: String?
        public var targetId: String?
        public var trashed: Bool

        public init(
            id: String, name: String, parentId: String, kind: RemoteItemKind, content: StagedContent? = nil,
            appProperties: [String: String] = [:], description: String? = nil, targetId: String? = nil, trashed: Bool = false
        ) {
            self.id = id
            self.name = name
            self.parentId = parentId
            self.kind = kind
            self.content = content
            self.appProperties = appProperties
            self.description = description
            self.targetId = targetId
            self.trashed = trashed
        }
    }

    public nonisolated let id: DestinationID
    public nonisolated let capabilities: DestinationCapabilities
    public nonisolated let rootId: String

    public private(set) var items: [String: Item] = [:]
    public private(set) var reserved: Set<String> = []
    public private(set) var contractViolations: [String] = []
    public private(set) var operationLog: [Operation] = []
    public var status: DestinationStatus = .active
    public var quotaValue: Quota? = Quota(totalBytes: 2_000 * GlobalSettings.GiB, usedBytes: 0, availableBytes: 2_000 * GlobalSettings.GiB)
    public var viewsPermitted = true
    /// `list(under: nil)` covers every item of the account (other roots too), as on Drive.
    public var listsWholeAccount = false
    private var failures: [Operation: [DestinationError]] = [:]
    private var crashes: [Operation: Int] = [:]
    private var sessions: [String: UploadRequest] = [:]
    private var nextId = 1

    public init(id: DestinationID = .googleDrive, reservesIds: Bool = true, rootName: String = "Camera Uploads") {
        self.id = id
        self.rootId = reservesIds ? "root" : ""
        self.capabilities = DestinationCapabilities(
            supportsViews: reservesIds, supportsAppProperties: reservesIds, supportsQuota: true,
            supportsDescription: reservesIds, reservesIds: reservesIds, verifiedHash: reservesIds ? .md5 : .sha256)
        if reservesIds {
            items["root"] = Item(id: "root", name: rootName, parentId: "", kind: .folder, content: nil,
                                 appProperties: [AppPropertyKey.root: "1", AppPropertyKey.schema: "1"], description: nil,
                                 targetId: nil, trashed: false)
        }
    }

    public nonisolated var root: RemoteFolderRef { .root(remoteId: rootId) }

    // MARK: Test controls

    public func failNext(_ op: Operation, with error: DestinationError, times: Int = 1) {
        failures[op, default: []].append(contentsOf: Array(repeating: error, count: times))
    }

    public func crashAfterEffect(_ op: Operation, times: Int = 1) { crashes[op, default: 0] += times }
    public func setStatus(_ value: DestinationStatus) { status = value }
    public func setViewsPermitted(_ value: Bool) { viewsPermitted = value }
    public func setListsWholeAccount(_ value: Bool) { listsWholeAccount = value }

    /// Removes an item as an owner would in the Drive UI (not something the app can do).
    public func externallyDelete(_ remoteId: String) { items[remoteId] = nil }
    public func externallyTrash(_ remoteId: String) { items[remoteId]?.trashed = true }
    public func externallyModify(_ remoteId: String, content: StagedContent) { items[remoteId]?.content = content }

    public func put(_ item: Item) { items[item.id] = item }

    public var files: [Item] { items.values.filter { $0.kind == .file }.sorted { $0.id < $1.id } }
    public var folders: [Item] { items.values.filter { $0.kind == .folder }.sorted { $0.id < $1.id } }
    public var shortcuts: [Item] { items.values.filter { $0.kind == .shortcut }.sorted { $0.id < $1.id } }

    public func children(of parentId: String) -> [Item] {
        items.values.filter { $0.parentId == parentId }.sorted { $0.name < $1.name }
    }

    /// Path of display names from the root, e.g. `2026/11/x.HEIC`.
    public func path(of remoteId: String) -> String {
        var parts: [String] = []
        var current = items[remoteId]
        while let item = current, item.id != rootId, !item.id.isEmpty {
            parts.insert(item.name, at: 0)
            current = items[item.parentId]
        }
        return parts.joined(separator: "/")
    }

    private func step(_ op: Operation) throws {
        operationLog.append(op)
        if var queue = failures[op], !queue.isEmpty {
            let error = queue.removeFirst()
            failures[op] = queue
            throw error
        }
    }

    private func crashIfRequested(_ op: Operation) throws {
        if let n = crashes[op], n > 0 {
            crashes[op] = n - 1
            throw CrashAfterEffect()
        }
    }

    private func newId(_ prefix: String) -> String {
        defer { nextId += 1 }
        return "\(prefix)\(nextId)"
    }

    private func requireParent(_ ref: RemoteFolderRef) throws -> Item? {
        if ref.remoteId == rootId, !capabilities.reservesIds { return nil }
        guard let parent = items[ref.remoteId] else { throw DestinationError.folderMissing(logicalPath: ref.logicalPath) }
        if parent.trashed {
            throw parent.id == rootId ? DestinationError.rootTrashed : DestinationError.folderTrashed(logicalPath: ref.logicalPath)
        }
        return parent
    }

    private func consumeReservation(_ id: String?) throws -> String {
        guard capabilities.reservesIds else { return newId("p") }
        guard let id else {
            contractViolations.append("create without reserved id")
            throw DestinationError.itemRejected(reason: "id not reserved")
        }
        if items[id] != nil { throw DestinationError.alreadyExists(remoteId: id) }
        guard reserved.remove(id) != nil else {
            contractViolations.append("create with unreserved id \(id)")
            throw DestinationError.itemRejected(reason: "id not reserved")
        }
        return id
    }

    /// Like Drive, an item inside a trashed folder reports itself as trashed.
    private func reportsTrashed(_ item: Item) -> Bool {
        guard capabilities.reservesIds else { return item.trashed }
        var current: Item? = item
        var hops = 0
        while let candidate = current, hops < 64 {
            if candidate.trashed { return true }
            current = items[candidate.parentId]
            hops += 1
        }
        return false
    }

    private func remote(_ item: Item) -> RemoteItem {
        RemoteItem(remoteId: item.id, name: item.name, parentIds: [item.parentId], kind: item.kind,
                   size: item.content?.size, md5: item.content?.md5, sha256: item.content?.sha256,
                   appProperties: item.appProperties, shortcutTargetId: item.targetId, trashed: reportsTrashed(item),
                   relativePath: capabilities.reservesIds ? nil : path(of: item.id))
    }

    private func result(_ item: Item) -> UploadResult {
        UploadResult(remoteId: item.id, finalName: item.name, verifiedHash: item.content?.hash(capabilities.verifiedHash) ?? "",
                     parentIds: [item.parentId], trashed: item.trashed, size: item.content?.size ?? 0)
    }

    private func folderRef(_ item: Item, logicalPath: String) -> RemoteFolderRef {
        RemoteFolderRef(logicalPath: logicalPath, remoteId: item.id, displayPath: path(of: item.id))
    }

    // MARK: Destination

    public func checkAvailability() async -> DestinationStatus {
        operationLog.append(.availability)
        if capabilities.reservesIds, let root = items[rootId] {
            if root.trashed { return .paused(.rootTrashed) }
        } else if capabilities.reservesIds {
            return .paused(.rootMissing)
        }
        return status
    }

    public func reserveIds(count: Int, kind: ReservedIdKind) async throws -> [String] {
        try step(.reserve)
        let ids = (0..<count).map { _ in newId(kind == .shortcuts ? "s" : "f") }
        reserved.formUnion(ids)
        return ids
    }

    public func ensureFolder(_ request: FolderRequest) async throws -> RemoteFolderRef {
        try step(.ensureFolder)
        let parent = try requireParent(request.parent)
        let parentId = parent?.id ?? rootId
        if let reservedId = request.reservedId, let existing = items[reservedId] {
            guard existing.kind == .folder, existing.parentId == parentId else { throw DestinationError.alreadyExists(remoteId: reservedId) }
            return folderRef(existing, logicalPath: request.logicalPath)
        }
        if !capabilities.reservesIds,
           let existing = items.values.first(where: { $0.parentId == parentId && $0.name == request.name && $0.kind == .folder }) {
            return folderRef(existing, logicalPath: request.logicalPath)
        }
        let id = try consumeReservation(request.reservedId)
        let item = Item(id: id, name: request.name, parentId: parentId, kind: .folder, content: nil,
                        appProperties: request.appProperties, description: nil, targetId: nil, trashed: false)
        items[id] = item
        try crashIfRequested(.ensureFolder)
        return folderRef(item, logicalPath: request.logicalPath)
    }

    public func upload(_ request: UploadRequest, onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        try step(.upload)
        let parent = try requireParent(request.parent)
        let parentId = parent?.id ?? rootId
        if capabilities.reservesIds {
            if let rid = request.reservedRemoteId, items[rid] != nil { throw DestinationError.alreadyExists(remoteId: rid) }
            let session = "session-\(newId(""))"
            sessions[session] = request
            try await onSession(SessionCheckpoint(sessionRef: session, md5: request.content.md5, totalBytes: request.content.size))
            let id = try consumeReservation(request.reservedRemoteId)
            sessions[session] = nil
            let item = Item(id: id, name: request.fileName, parentId: parentId, kind: .file, content: request.content,
                            appProperties: request.appProperties, description: request.description, targetId: nil, trashed: false)
            items[id] = item
            try crashIfRequested(.upload)
            return result(item)
        }
        // Local-folder semantics.
        if let existing = items.values.first(where: { $0.parentId == parentId && $0.name == request.fileName && $0.kind == .file }) {
            if existing.content?.sha256 == request.content.sha256 { return result(existing) }
            guard request.kind == .original else { throw DestinationError.foreignFile }
            var n = 0
            var name: String
            repeat {
                n += 1
                let base = (request.fileName as NSString).deletingPathExtension
                let ext = (request.fileName as NSString).pathExtension
                name = "\(base) (conflict-\(String(format: "%06d", n)))" + (ext.isEmpty ? "" : ".\(ext)")
            } while items.values.contains { $0.parentId == parentId && $0.name == name }
            let item = Item(id: newId("p"), name: name, parentId: parentId, kind: .file, content: request.content,
                            appProperties: [:], description: nil, targetId: nil, trashed: false)
            items[item.id] = item
            try crashIfRequested(.upload)
            return result(item)
        }
        let item = Item(id: newId("p"), name: request.fileName, parentId: parentId, kind: .file, content: request.content,
                        appProperties: [:], description: nil, targetId: nil, trashed: false)
        items[item.id] = item
        try crashIfRequested(.upload)
        return result(item)
    }

    public func resumeUpload(_ request: UploadRequest, session: SessionCheckpoint,
                             onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        try step(.resume)
        guard let opened = sessions[session.sessionRef] else { throw DestinationError.sessionExpired }
        sessions[session.sessionRef] = nil
        // The file lands in the folder the session was opened for, whatever the new request plans.
        let parent = try requireParent(opened.parent)
        let id = try consumeReservation(request.reservedRemoteId)
        let item = Item(id: id, name: request.fileName, parentId: parent?.id ?? rootId, kind: .file, content: request.content,
                        appProperties: request.appProperties, description: request.description, targetId: nil, trashed: false)
        items[id] = item
        return result(item)
    }

    /// Drops all open sessions (expiry, long sleep).
    public func expireSessions() { sessions.removeAll() }

    public func probe(remoteId: String) async throws -> RemoteItem? {
        try step(.probe)
        return items[remoteId].map(remote)
    }

    public func replaceContent(remoteId: String, _ request: UploadRequest) async throws -> UploadResult {
        try step(.replace)
        guard var item = items[remoteId], item.kind == .file else { throw DestinationError.notFound }
        if !capabilities.reservesIds, let expected = request.expectedPriorHash, item.content?.sha256 != expected {
            throw DestinationError.foreignModified
        }
        item.content = request.content
        item.description = request.description ?? item.description
        items[remoteId] = item
        try crashIfRequested(.replace)
        return result(item)
    }

    public func move(remoteId: String, name: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem {
        try step(.move)
        guard var item = items[remoteId] else { throw DestinationError.notFound }
        let target = try requireParent(to)
        item.parentId = target?.id ?? rootId
        item.name = name
        items[remoteId] = item
        try crashIfRequested(.move)
        return remote(item)
    }

    public func renameFolder(_ folder: RemoteFolderRef, newName: String) async throws -> RemoteFolderRef {
        try step(.rename)
        guard var item = items[folder.remoteId], item.kind == .folder else {
            throw DestinationError.folderMissing(logicalPath: folder.logicalPath)
        }
        item.name = newName
        items[item.id] = item
        try crashIfRequested(.rename)
        return folderRef(item, logicalPath: folder.logicalPath)
    }

    public nonisolated func list(under folder: RemoteFolderRef?) -> AsyncThrowingStream<RemoteItem, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for item in try await self.listItems(under: folder) { continuation.yield(item) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func listItems(under folder: RemoteFolderRef?) throws -> [RemoteItem] {
        try step(.list)
        // Without a folder Drive lists the whole account, not only the app's root.
        if folder == nil, capabilities.reservesIds, listsWholeAccount { return items.values.map(remote).sorted { $0.remoteId < $1.remoteId } }
        let base = folder?.remoteId ?? rootId
        var result: [RemoteItem] = []
        var queue = [base]
        while let current = queue.popLast() {
            for child in items.values where child.parentId == current && child.id != current {
                result.append(remote(child))
                if child.kind == .folder { queue.append(child.id) }
            }
        }
        return result.sorted { $0.remoteId < $1.remoteId }
    }

    public func quota() async throws -> Quota? { quotaValue }

    // MARK: ViewDestination

    public func createShortcut(_ request: ShortcutRequest) async throws -> RemoteItem {
        try step(.shortcut)
        guard viewsPermitted else { throw DestinationError.viewsNotPermitted }
        let parent = try requireParent(request.parent)
        let id = try consumeReservation(request.reservedId)
        let item = Item(id: id, name: request.name, parentId: parent?.id ?? rootId, kind: .shortcut, content: nil,
                        appProperties: request.appProperties, description: nil, targetId: request.targetId, trashed: false)
        items[id] = item
        try crashIfRequested(.shortcut)
        return remote(item)
    }

    public func moveShortcut(remoteId: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem {
        try step(.shortcut)
        guard var item = items[remoteId], item.kind == .shortcut else { throw DestinationError.notFound }
        let parent = try requireParent(to)
        item.parentId = parent?.id ?? rootId
        items[remoteId] = item
        return remote(item)
    }

    public func trashShortcut(remoteId: String) async throws {
        try step(.shortcut)
        guard var item = items[remoteId] else { throw DestinationError.notFound }
        guard item.kind == .shortcut else {
            contractViolations.append("trash of non-shortcut \(remoteId)")
            throw DestinationError.itemRejected(reason: "only shortcuts may be trashed")
        }
        item.trashed = true
        items[remoteId] = item
    }

    // MARK: RootManaging

    public func findRoots() async throws -> [RemoteItem] {
        items.values.filter { $0.appProperties[AppPropertyKey.root] == "1" && !$0.trashed }.map(remote)
    }

    public func checkRoot(remoteId: String) async throws -> RootCheck {
        guard let item = items[remoteId] else { return .missing }
        return item.trashed ? .trashed : .ok(remote(item))
    }

    public func createRoot(reservedId: String, name: String, appProperties: [String: String]) async throws -> RemoteItem {
        let id = try consumeReservation(reservedId)
        let item = Item(id: id, name: name, parentId: "", kind: .folder, content: nil, appProperties: appProperties,
                        description: nil, targetId: nil, trashed: false)
        items[id] = item
        return remote(item)
    }

    public func renameRoot(remoteId: String, newName: String) async throws -> RemoteItem {
        guard var item = items[remoteId] else { throw DestinationError.rootMissing }
        item.name = newName
        items[remoteId] = item
        return remote(item)
    }

    public func untrash(remoteId: String) async throws -> RemoteItem {
        guard var item = items[remoteId] else { throw DestinationError.notFound }
        item.trashed = false
        items[remoteId] = item
        return remote(item)
    }

    public func updateMetadata(remoteId: String, description: String?, appProperties: [String: String]) async throws {
        guard var item = items[remoteId] else { throw DestinationError.notFound }
        if let description { item.description = description }
        item.appProperties.merge(appProperties) { _, new in new }
        items[remoteId] = item
    }
}
