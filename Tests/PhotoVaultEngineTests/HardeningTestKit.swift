import CryptoKit
import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

// MARK: Harness

extension Harness {
    /// Emulates a lost database: a new empty store; destinations, the Photos library, the clock and
    /// the staging directory stay as they were. Destination records must be added again.
    func loseDatabase(localContent reader: (any LocalContentReading)? = nil) async throws {
        try await replaceStore(try Store.inMemory(), localContent: reader)
        // The settings were in the lost database too.
        if !organizationEnabled { try await switchOrganizationOff() }
    }

    func replaceStore(_ replacement: Store, localContent reader: (any LocalContentReading)? = nil) async throws {
        store = replacement
        localContent = reader ?? localContent
        try await restart()
    }

    /// A real local destination in a temporary folder, registered under the NAS id.
    func useRealLocal(root folder: URL? = nil) async throws -> (destination: LocalFolderDestination, root: URL, reader: DirectoryReader) {
        let url = try folder ?? TestFiles.temporaryDirectory("nas")
        let destination = LocalFolderDestination(id: nasId, root: PlainURLRoot(url))
        _ = try await destination.writeMarker(DestinationMarker(id: nasId, createdAt: clock.now, archiveTimezone: utc.identifier))
        overrides = overrides.filter { $0.id != nasId } + [destination]
        await env.destinations.add(destination)
        let reader = DirectoryReader(root: url)
        localContent = reader
        try await restart()
        return (destination, url, reader)
    }

    func activity() throws -> [ActivityEvent] { try read { db in try ActivityRepository.recent(db) } }

    func destinationRecord(_ id: DestinationID) throws -> DestinationRecord {
        try #require(try read { db in try DestinationRepository.fetch(db, id: id) })
    }

    func shortcutRows(_ id: DestinationID) throws -> [ShortcutRecord] {
        try read { db in try ShortcutState.allCases.flatMap { try ShortcutRepository.fetch(db, destinationId: id, state: $0) } }
    }

    func folderRows(_ id: DestinationID) throws -> [RemoteFolder] {
        try read { db in try RemoteFolderRepository.fetchAll(db, destinationId: id).sorted { $0.logicalPath < $1.logicalPath } }
    }

    func nameAllocations() throws -> [String] {
        try read { db in
            try String.fetchAll(db, sql: "SELECT placement_category || '|' || placement_day || '|' || norm_stem || '|' || asset_key FROM name_alloc ORDER BY 1")
        }
    }

    func placements() throws -> [String: String] {
        try read { db in
            var map: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT asset_key, placement_category, placement_day, name_stem FROM asset") {
                map[row["asset_key"]] = "\(row["placement_category"] as String? ?? "-")|\(row["placement_day"] as String? ?? "-")|\(row["name_stem"] as String? ?? "-")"
            }
            return map
        }
    }

    func count(of op: FakeDestination.Operation, on destination: FakeDestination) async -> Int {
        await destination.operationLog.filter { $0 == op }.count
    }
}

// MARK: Local content

/// Reads the folder of a local destination directly, as the composition root does over the bookmark.
struct DirectoryReader: LocalContentReading {
    let root: URL

    func readSidecar(destination: DestinationID, path: String) async throws -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(path))
    }

    func sha256(destination: DestinationID, path: String) async throws -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { return nil }
        return SHA256.hash(data: data).hexString
    }

    func archiveTimezone(destination: DestinationID) async throws -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".photovault/destination.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["archiveTimezone"] as? String
    }
}

/// Relative paths and sizes of every regular file below `root`, `.photovault` included.
func treeListing(_ root: URL) -> [String: Int] {
    var result: [String: Int] = [:]
    let walker = FileManager.default.enumerator(atPath: root.path)
    while let relative = walker?.nextObject() as? String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
        result[relative] = (attributes?[.size] as? Int) ?? 0
    }
    return result
}

/// Folders below `root` as relative paths (`.photovault` excluded).
func folderListing(_ root: URL) -> [String] {
    var result: [String] = []
    let walker = FileManager.default.enumerator(atPath: root.path)
    while let relative = walker?.nextObject() as? String {
        guard !relative.hasPrefix(".photovault") else { continue }
        let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path)
        if attributes?[.type] as? FileAttributeType == .typeDirectory { result.append(relative) }
    }
    return result.sorted()
}

// MARK: Controllable Drive

/// A Drive-like destination whose listing can be hidden and whose root can be changed, over a
/// `FakeDestination` (whose own root is fixed).
final class ControllableDrive: RootManaging, ViewDestination, @unchecked Sendable {
    let inner: FakeDestination
    private let lock = NSLock()
    private var hidden = false
    private var root: String

    init(_ inner: FakeDestination) {
        self.inner = inner
        root = inner.rootId
    }

    /// `list(under: nil)` shows nothing; a walk of the root (`list(under: ref)`) still sees the files.
    var hidesListing: Bool {
        get { lock.withLock { hidden } }
        set { lock.withLock { hidden = newValue } }
    }

    var activeRoot: String {
        get { lock.withLock { root } }
        set { lock.withLock { root = newValue } }
    }

    var id: DestinationID { inner.id }
    var capabilities: DestinationCapabilities { inner.capabilities }

    func checkAvailability() async -> DestinationStatus {
        switch (try? await inner.checkRoot(remoteId: activeRoot)) ?? .missing {
        case .ok: return await inner.status
        case .missing: return .paused(.rootMissing)
        case .trashed: return .paused(.rootTrashed)
        }
    }

    func reserveIds(count: Int, kind: ReservedIdKind) async throws -> [String] { try await inner.reserveIds(count: count, kind: kind) }
    func ensureFolder(_ request: FolderRequest) async throws -> RemoteFolderRef { try await inner.ensureFolder(request) }
    func upload(_ request: UploadRequest, onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        try await inner.upload(request, onSession: onSession)
    }
    func resumeUpload(_ request: UploadRequest, session: SessionCheckpoint, onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        try await inner.resumeUpload(request, session: session, onSession: onSession)
    }
    func probe(remoteId: String) async throws -> RemoteItem? { try await inner.probe(remoteId: remoteId) }
    func replaceContent(remoteId: String, _ request: UploadRequest) async throws -> UploadResult { try await inner.replaceContent(remoteId: remoteId, request) }
    func move(remoteId: String, name: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem {
        try await inner.move(remoteId: remoteId, name: name, from: from, to: to)
    }
    func renameFolder(_ folder: RemoteFolderRef, newName: String) async throws -> RemoteFolderRef { try await inner.renameFolder(folder, newName: newName) }
    func quota() async throws -> Quota? { try await inner.quota() }

    func list(under folder: RemoteFolderRef?) -> AsyncThrowingStream<RemoteItem, any Error> {
        if folder == nil {
            if hidesListing { return AsyncThrowingStream { $0.finish() } }
            return inner.list(under: .root(remoteId: activeRoot))
        }
        return inner.list(under: folder)
    }

    func createShortcut(_ request: ShortcutRequest) async throws -> RemoteItem { try await inner.createShortcut(request) }
    func moveShortcut(remoteId: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem {
        try await inner.moveShortcut(remoteId: remoteId, from: from, to: to)
    }
    func trashShortcut(remoteId: String) async throws { try await inner.trashShortcut(remoteId: remoteId) }

    func findRoots() async throws -> [RemoteItem] { try await inner.findRoots() }
    func checkRoot(remoteId: String) async throws -> RootCheck { try await inner.checkRoot(remoteId: remoteId) }
    func createRoot(reservedId: String, name: String, appProperties: [String: String]) async throws -> RemoteItem {
        try await inner.createRoot(reservedId: reservedId, name: name, appProperties: appProperties)
    }
    func renameRoot(remoteId: String, newName: String) async throws -> RemoteItem { try await inner.renameRoot(remoteId: remoteId, newName: newName) }
    func untrash(remoteId: String) async throws -> RemoteItem { try await inner.untrash(remoteId: remoteId) }
    func updateMetadata(remoteId: String, description: String?, appProperties: [String: String]) async throws {
        try await inner.updateMetadata(remoteId: remoteId, description: description, appProperties: appProperties)
    }
}

extension FakeDestination {
    /// Rewrites the app properties of an item, as an older or foreign app version would have left them.
    func rewriteProperties(of remoteId: String, _ change: @Sendable ([String: String]) -> [String: String]) {
        guard var item = items[remoteId] else { return }
        item.appProperties = change(item.appProperties)
        put(item)
    }
}
