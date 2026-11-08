import Foundation
import PhotoVaultCore

/// What to do with a folder-rename `move_job` found `inProgress` at startup (spec 8.9.4).
public enum RenameRecoveryDecision: Hashable, Sendable {
    /// Renamed already: commit `display_name` and mark the job done.
    case commit
    /// Not renamed yet: run the rename again.
    case retry
    /// Neither name exists: flag an integrity check.
    case integrityCheck
}

public enum FolderRenameRecovery {
    public static func decide(oldExists: Bool, newExists: Bool) -> RenameRecoveryDecision {
        if oldExists { return .retry }
        return newExists ? .commit : .integrityCheck
    }
}

extension LocalFileOps {
    func renameRecovery(oldPath: String, newPath: String) throws -> RenameRecoveryDecision {
        try withRoot { root in
            func folderExists(_ path: String) throws -> Bool {
                try LocalPath.requireUserPath(path)
                let (parentPath, name) = try LocalPath.split(path)
                let parent: DirectoryHandle
                do { parent = try root.openDirectory(parentPath) } catch DestinationError.notFound { return false }
                return try parent.status(name)?.isDirectory ?? false
            }
            return FolderRenameRecovery.decide(oldExists: try folderExists(oldPath), newExists: try folderExists(newPath))
        }
    }
}
