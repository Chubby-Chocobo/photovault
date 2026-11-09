import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Rebuilds the `RemoteFolderRef` of a folder that already exists, from the `remote_folder` rows of
/// the folder and its ancestors (logical path → remote id, display names → display path).
enum FolderRefResolver {
    static func ref(_ db: Database, destinationId: DestinationID, logicalPath: String, rootId: String) throws -> RemoteFolderRef {
        if logicalPath.isEmpty { return .root(remoteId: rootId) }
        var names: [String] = []
        var components: [String] = []
        let parts = logicalPath.split(separator: "/").map(String.init)
        var deepest: RemoteFolder?
        for (index, part) in parts.enumerated() {
            components.append(part)
            let path = components.joined(separator: "/")
            let row = try RemoteFolderRepository.fetch(db, destinationId: destinationId, logicalPath: path)
            // Not every prefix of a logical path is a folder (`camera` is not); the folder itself must exist.
            guard let row, row.created, row.remoteId != nil else {
                if index == parts.count - 1 { throw DestinationError.folderMissing(logicalPath: path) }
                continue
            }
            names.append(row.displayName)
            deepest = row
        }
        guard let remoteId = deepest?.remoteId else { throw DestinationError.folderMissing(logicalPath: logicalPath) }
        return RemoteFolderRef(logicalPath: logicalPath, remoteId: remoteId, displayPath: names.joined(separator: "/"))
    }

    static func rootId(_ record: DestinationRecord) -> String { record.config.driveRootId ?? "" }
}
