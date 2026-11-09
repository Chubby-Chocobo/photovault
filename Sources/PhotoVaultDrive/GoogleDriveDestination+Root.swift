import Foundation
import PhotoVaultCore

extension GoogleDriveDestination {
    public func findRoots() async throws -> [RemoteItem] {
        let query = DriveQuery.all.appProperty(AppPropertyKey.root, "1").notTrashed.mimeType(DriveMime.folder)
        var roots: [RemoteItem] = []
        for try await item in stream(query) { roots.append(item) }
        return roots
    }

    /// Folders directly inside `parentId` (a root or one of its folders), without descending.
    public func childFolders(of parentId: String) async throws -> [RemoteItem] {
        let query = DriveQuery.all.parent(parentId).notTrashed.mimeType(DriveMime.folder)
        var folders: [RemoteItem] = []
        for try await item in stream(query) { folders.append(item) }
        return folders
    }

    public func checkRoot(remoteId: String) async throws -> RootCheck {
        do {
            let file = try await api.get(remoteId)
            return file.trashed == true ? .trashed : .ok(file.remoteItem)
        } catch DestinationError.notFound {
            return .missing
        }
    }

    public func createRoot(reservedId: String, name: String, appProperties: [String: String]) async throws -> RemoteItem {
        let write = DriveFileWrite(id: reservedId, name: name, mimeType: DriveMime.folder,
                                   appProperties: try Self.prepared(appProperties))
        return try await createVerified(write, name: name, mimeType: DriveMime.folder, parent: nil).remoteItem
    }

    public func renameRoot(remoteId: String, newName: String) async throws -> RemoteItem {
        try await api.update(remoteId, DriveFileWrite(name: newName)).remoteItem
    }

    /// "Khôi phục giúp tôi": only on the owner's request.
    public func untrash(remoteId: String) async throws -> RemoteItem {
        try await api.update(remoteId, DriveFileWrite(trashed: false)).remoteItem
    }

    public func updateMetadata(remoteId: String, description: String?, appProperties: [String: String]) async throws {
        let properties = try Self.prepared(appProperties)
        _ = try await api.update(remoteId, DriveFileWrite(appProperties: properties, description: description))
    }
}
