import Foundation
import PhotoVaultCore

/// One backup file found at a destination, with everything recovery can learn about it without
/// downloading it (spec 8.15).
struct RemoteFileEntry: Sendable {
    var item: RemoteItem
    /// Logical path of the folder it sits in; nil when that folder is not one of ours.
    var parentLogical: String?
    /// Id of the folder it sits in: the Drive parent id, or the directory path of a local destination.
    var parentFolderId: String?
    var resType: ResourceType?
    /// `pvAssetId` (Drive) or the sidecar's `assetKey`: a key or its `h:` form.
    var claimedKey: String?
    var localId: String?
    var cloudId: String?
    var name: NameFingerprint?
    var epoch: Int64?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?
    /// Hash the app wrote: MD5 on Drive, the sidecar's SHA-256 on a local destination.
    var uploadedHash: String?
    var expectedSize: Int64?
    /// Hashes of the file's content as the destination or its sidecar reports them. A database loss
    /// drops the resource hashes the sidecar lists; they are put back so the sidecar is built the same.
    var contentMd5: String?
    var contentSha256: String?
    /// Camera fields the sidecar carried; the scan alone cannot know them.
    var camera: SidecarDocument.Camera?
}

struct RemoteFolderEntry: Sendable {
    var logicalPath: String
    var remoteId: String
    var displayName: String
    var day: ArchiveDay?
    /// Extra folder of a split day (`camera/<day>@<slot>`); nil for the main folder.
    var slot: String?
    var placeName: String?
}

struct RemoteShortcutEntry: Sendable {
    var view: ViewKind
    var claimedKey: String
    var shortcutId: String
    var targetId: String?
    var parentLogical: String?
}

struct RemoteInventory: Sendable {
    var files: [RemoteFileEntry] = []
    var folders: [RemoteFolderEntry] = []
    var shortcuts: [RemoteShortcutEntry] = []
    /// Items that are not ours or not understood; they are never touched.
    var ignored = 0
    /// Folders of the old `YYYY/MM` layout. A root that has any is not recovered from.
    var legacyFolders = 0
    /// Archive timezone the destination remembers (`pvArchiveTZ`, `destination.json`).
    var archiveTimezone: String?
}

/// Reads a destination into a `RemoteInventory`. Drive: items carrying `pvSchema=1` under the root.
/// Local: the folder tree, interpreted through the layout, plus the JSON sidecars.
struct RemoteInventoryLoader: Sendable {
    let env: EngineEnvironment
    let record: DestinationRecord
    let destination: any Destination

    private static let maxSidecarBytes: Int64 = 1 << 20

    func load() async throws -> RemoteInventory {
        var items: [RemoteItem] = []
        for try await item in destination.list(under: nil) {
            try Task.checkCancellation()
            items.append(item)
        }
        return destination.capabilities.supportsAppProperties ? try await drive(items) : try await local(items)
    }

    // MARK: Drive

    private func drive(_ items: [RemoteItem]) async throws -> RemoteInventory {
        var inventory = RemoteInventory()
        let rootId = record.config.driveRootId ?? ""
        if let managing = destination as? any RootManaging, !rootId.isEmpty, case .ok(let root) = try await managing.checkRoot(remoteId: rootId) {
            inventory.archiveTimezone = root.appProperties[AppPropertyKey.archiveTimezone]
        }
        let ours = items.filter { $0.appProperties[AppPropertyKey.schema] == AppPropertyCodec.schemaVersion }
        let byId = Dictionary(ours.map { ($0.remoteId, $0) }, uniquingKeysWith: { first, _ in first })
        var underRoot: [String: Bool] = [:]
        func isUnderRoot(_ item: RemoteItem) -> Bool {
            if let known = underRoot[item.remoteId] { return known }
            var trail: [String] = []
            var current = item
            var result = false
            while true {
                trail.append(current.remoteId)
                if current.trashed { break }
                guard let parent = current.parentIds.first else { break }
                if parent == rootId { result = true; break }
                if let known = underRoot[parent] { result = known; break }
                guard let next = byId[parent], !trail.contains(next.remoteId) else { break }
                current = next
            }
            for id in trail { underRoot[id] = result }
            return result
        }
        var logicalById: [String: String] = [:]
        for item in ours where item.kind == .folder && isUnderRoot(item) {
            guard let value = item.appProperties[AppPropertyKey.logical], !value.hasPrefix("h:") else {
                inventory.ignored += 1
                continue
            }
            logicalById[item.remoteId] = value
            if LegacyRootProbe.isLegacyLogicalPath(value) { inventory.legacyFolders += 1 }
            let (day, slot, place) = Self.dayFolder(logical: value, name: item.name)
            inventory.folders.append(RemoteFolderEntry(
                logicalPath: value, remoteId: item.remoteId, displayName: item.name, day: day, slot: slot, placeName: place))
        }
        func parentLogical(_ item: RemoteItem) -> String? {
            guard let parent = item.parentIds.first else { return nil }
            return parent == rootId ? "" : logicalById[parent]
        }
        for item in ours where item.kind != .folder {
            guard isUnderRoot(item) else {
                inventory.ignored += 1
                continue
            }
            switch item.kind {
            case .file:
                inventory.files.append(RemoteFileEntry(
                    item: item, parentLogical: parentLogical(item), parentFolderId: item.parentIds.first,
                    resType: item.appProperties[AppPropertyKey.resType].flatMap(AppPropertyCodec.decodeResourceType),
                    claimedKey: item.appProperties[AppPropertyKey.assetId], name: NameFingerprint.parse(item.name),
                    uploadedHash: item.md5, expectedSize: item.size, contentMd5: item.md5, contentSha256: item.sha256))
            case .shortcut:
                guard let raw = item.appProperties[AppPropertyKey.view], let view = ViewKind(rawValue: raw),
                      let key = item.appProperties[AppPropertyKey.assetId] else {
                    inventory.ignored += 1
                    continue
                }
                inventory.shortcuts.append(RemoteShortcutEntry(
                    view: view, claimedKey: key, shortcutId: item.remoteId, targetId: item.shortcutTargetId,
                    parentLogical: parentLogical(item) ?? Self.plainLogical(item.appProperties[AppPropertyKey.logical])))
            case .folder:
                break
            }
        }
        inventory.files.sort { $0.item.remoteId < $1.item.remoteId }
        return inventory
    }

    private static func plainLogical(_ value: String?) -> String? {
        guard let value, !value.hasPrefix("h:") else { return nil }
        return value
    }

    /// `camera/2026-11-08` named `2026-11-08 Đà Lạt`, or the extra folder `camera/2026-11-08@p…`.
    static func dayFolder(logical: String, name: String) -> (ArchiveDay?, String?, String?) {
        guard let (day, slot) = DynamicLayout.parseCameraDay(logical), name.hasPrefix(day.description) else { return (nil, nil, nil) }
        guard name.count == 10 || name.dropFirst(10).hasPrefix(" ") else { return (day, slot, nil) }
        let place = name.dropFirst(10).trimmingCharacters(in: .whitespaces)
        return (day, slot, place.isEmpty ? nil : place)
    }

    // MARK: Local

    private func local(_ items: [RemoteItem]) async throws -> RemoteInventory {
        var inventory = RemoteInventory()
        var folderByPath: [String: LocalFolderInfo] = [:]
        var folderIdByPath: [String: String] = [:]
        for item in items where item.kind == .folder {
            let path = item.relativePath ?? item.remoteId
            guard let info = LocalTreeInterpreter.folder(displayPath: path) else {
                if LegacyRootProbe.isLegacyFolder(displayPath: path) { inventory.legacyFolders += 1 }
                inventory.ignored += 1
                continue
            }
            folderByPath[path] = info
            folderIdByPath[path] = item.remoteId
            inventory.folders.append(RemoteFolderEntry(
                logicalPath: info.logicalPath, remoteId: item.remoteId, displayName: info.displayName, day: info.day, placeName: info.placeName))
        }
        inventory.archiveTimezone = try await env.localContent?.archiveTimezone(destination: record.id)
        let files = items.filter { $0.kind == .file && !$0.trashed }
        var documents: [String: [(document: SidecarDocument, file: RemoteItem, hash: String)]] = [:]
        for file in files where file.name.lowercased().hasSuffix(".json") {
            let path = file.relativePath ?? file.remoteId
            guard let reader = env.localContent, folderByPath[Self.directory(of: path)] != nil, (file.size ?? 0) <= Self.maxSidecarBytes,
                  let data = try await reader.readSidecar(destination: record.id, path: path),
                  let document = SidecarDocument.parse(data) else { continue }
            documents[Self.directory(of: path), default: []].append((document, file, data.sha256Hex))
            if inventory.archiveTimezone == nil { inventory.archiveTimezone = document.archiveTimezone }
        }
        for file in files {
            let path = file.relativePath ?? file.remoteId
            let directory = Self.directory(of: path)
            guard let folder = folderByPath[directory], let name = NameFingerprint.parse(file.name) else {
                inventory.ignored += 1
                continue
            }
            var entry = RemoteFileEntry(
                item: file, parentLogical: folder.logicalPath, parentFolderId: folderIdByPath[directory], name: name, expectedSize: file.size)
            let siblings = documents[directory] ?? []
            let lowered = file.name.lowercased()
            if lowered.hasSuffix(".json"), let own = siblings.first(where: { $0.file.remoteId == file.remoteId }) {
                entry.resType = .sidecarJson
                entry.uploadedHash = own.hash
                Self.apply(own.document, to: &entry)
            } else if lowered.hasSuffix(".xmp") {
                entry.resType = .sidecarXmp
                if let document = siblings.first(where: { NameFingerprint.parse($0.file.name)?.fullStem == name.fullStem })?.document {
                    Self.apply(document, to: &entry)
                }
                entry.uploadedHash = try await env.localContent?.sha256(destination: record.id, path: path)
            } else if let hit = siblings.lazy.compactMap({ doc -> (SidecarDocument, SidecarDocument.Resource)? in
                doc.document.resources.first { $0.backupName == file.name }.map { (doc.document, $0) }
            }).first {
                entry.resType = AppPropertyCodec.decodeResourceType(hit.1.type)
                entry.uploadedHash = hit.1.sha256
                entry.expectedSize = hit.1.size ?? file.size
                entry.contentMd5 = hit.1.md5
                entry.contentSha256 = hit.1.sha256
                Self.apply(hit.0, to: &entry)
            }
            inventory.files.append(entry)
        }
        inventory.files.sort { $0.item.remoteId < $1.item.remoteId }
        return inventory
    }

    private static func apply(_ document: SidecarDocument, to entry: inout RemoteFileEntry) {
        entry.claimedKey = document.assetKey
        entry.localId = document.localIdentifier
        entry.cloudId = document.cloudIdentifier
        entry.epoch = document.creationEpoch
        entry.pixelWidth = document.pixelWidth
        entry.pixelHeight = document.pixelHeight
        entry.duration = document.duration
        entry.camera = document.camera
    }

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
