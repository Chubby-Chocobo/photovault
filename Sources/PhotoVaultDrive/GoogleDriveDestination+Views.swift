import Foundation
import PhotoVaultCore

extension GoogleDriveDestination {
    public func createShortcut(_ request: ShortcutRequest) async throws -> RemoteItem {
        let write = DriveFileWrite(id: request.reservedId, name: request.name, mimeType: DriveMime.shortcut,
                                   parents: [request.parent.remoteId],
                                   appProperties: try Self.prepared(request.appProperties),
                                   shortcutDetails: DriveFile.ShortcutDetails(targetId: request.targetId))
        return try await shortcutOperation {
            try await createVerified(write, name: request.name, mimeType: DriveMime.shortcut, parent: request.parent,
                                     targetId: request.targetId).remoteItem
        }
    }

    public func moveShortcut(remoteId: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem {
        try await shortcutOperation {
            let file = try await api.update(remoteId, DriveFileWrite(), addParents: [to.remoteId], removeParents: [from.remoteId])
            if file.trashed == true { throw trashedError(to) }
            return file.remoteItem
        }
    }

    /// Only shortcuts may be trashed by the app: the item type is checked first.
    public func trashShortcut(remoteId: String) async throws {
        try await shortcutOperation {
            let existing = try await api.get(remoteId)
            guard existing.isShortcut else { throw DestinationError.itemRejected(reason: "not a shortcut") }
            _ = try await api.update(remoteId, DriveFileWrite(trashed: true))
        }
    }

    /// 403 on shortcut calls means the scope or account does not allow them (FR-103).
    private func shortcutOperation<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as DestinationError where DriveErrorMapper.isForbidden(error) {
            throw DestinationError.viewsNotPermitted
        }
    }
}
