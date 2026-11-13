import Foundation
import Photos
import PhotoVaultCore

extension PhotoKitSource {
    public func currentChangeToken() async throws -> ChangeToken {
        try requireAccess()
        return try Self.archive(PHPhotoLibrary.shared().currentChangeToken)
    }

    public func fetchPersistentChanges(since token: ChangeToken) async throws -> [PersistentChange] {
        try requireAccess()
        let persistentToken = try Self.unarchive(token)
        do {
            let result = try PHPhotoLibrary.shared().fetchPersistentChanges(since: persistentToken)
            var changes: [PersistentChange] = []
            for change in result { changes.append(try autoreleasepool { try Self.map(change) }) }
            return changes
        } catch {
            throw PhotosErrorMapper.map(error)
        }
    }


    private static func map(_ change: PHPersistentChange) throws -> PersistentChange {
        let assets = try change.changeDetails(for: .asset)
        let collections = try change.changeDetails(for: .assetCollection)
        let albumsChanged = !(collections.insertedLocalIdentifiers.isEmpty
            && collections.updatedLocalIdentifiers.isEmpty
            && collections.deletedLocalIdentifiers.isEmpty)
        return PersistentChange(
            token: try archive(change.changeToken),
            insertedLocalIds: assets.insertedLocalIdentifiers.sorted(),
            updatedLocalIds: assets.updatedLocalIdentifiers.sorted(),
            deletedLocalIds: assets.deletedLocalIdentifiers.sorted(),
            albumsChanged: albumsChanged
        )
    }

    static func archive(_ token: PHPersistentChangeToken) throws -> ChangeToken {
        do {
            return ChangeToken(data: try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true))
        } catch {
            throw PhotosSourceError.other(code: (error as NSError).code, domain: (error as NSError).domain)
        }
    }

    /// An unreadable token is treated as expired so the engine falls back to a rescan.
    static func unarchive(_ token: ChangeToken) throws -> PHPersistentChangeToken {
        guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token.data) else {
            throw PhotosSourceError.tokenExpired
        }
        return decoded
    }
}
