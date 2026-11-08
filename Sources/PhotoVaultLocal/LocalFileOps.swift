import Darwin
import Foundation
import PhotoVaultCore

/// Synchronous, fd-relative file operations of a local destination. Holds no mutable state, so the
/// destination actor can run it under a folder lock off its own executor.
struct LocalFileOps: Sendable {
    let access: any RootAccess
    let writer: AtomicFileWriter
    let log: any LogSink

    func withRoot<T>(_ body: (DirectoryHandle) throws -> T) throws -> T {
        try access.withRoot { url in try body(try DirectoryHandle.openRoot(url)) }
    }

    func userDirectory(_ root: DirectoryHandle, _ path: String, create: Bool = false) throws -> DirectoryHandle {
        try LocalPath.requireUserPath(path)
        return try root.openDirectory(path, create: create)
    }

    /// The directory holding a folder's children; a missing one is `folderMissing`.
    func parentDirectory(_ root: DirectoryHandle, _ ref: RemoteFolderRef) throws -> DirectoryHandle {
        do {
            return try userDirectory(root, ref.remoteId)
        } catch DestinationError.notFound {
            throw DestinationError.folderMissing(logicalPath: ref.logicalPath)
        }
    }

    func tmpDirectory(_ root: DirectoryHandle, create: Bool) throws -> DirectoryHandle {
        try root.openDirectory(LocalPath.reservedDirectory + "/" + LocalPath.tmpDirectory, create: create)
    }

    func item(_ st: stat, path: String) throws -> RemoteItem {
        let (parent, name) = try LocalPath.split(path)
        return RemoteItem(remoteId: path, name: name, parentIds: [parent], kind: st.isDirectory ? .folder : .file,
                          size: st.isRegular ? Int64(st.st_size) : nil, relativePath: path)
    }

    // MARK: Folders

    func ensureFolder(_ request: FolderRequest) throws -> RemoteFolderRef {
        try LocalPath.validate(name: request.name)
        let path = LocalPath.join(request.parent.remoteId, request.name)
        try LocalPath.requireUserPath(path)
        return try withRoot { root in
            let parent = try parentDirectory(root, request.parent)
            if let st = try parent.status(request.name) {
                if st.isSymlink { throw DestinationError.itemRejected(reason: "symlink") }
                guard st.isDirectory else { throw DestinationError.foreignFile }
            }
            _ = try parent.openChild(request.name, create: true)
            return RemoteFolderRef(logicalPath: request.logicalPath, remoteId: path, displayPath: path)
        }
    }

    func renameFolder(_ folder: RemoteFolderRef, newName: String) throws -> RemoteFolderRef {
        try LocalPath.validate(name: newName)
        let (parentPath, oldName) = try LocalPath.split(folder.remoteId)
        try LocalPath.requireUserPath(folder.remoteId)
        let newPath = LocalPath.join(parentPath, newName)
        let renamed = RemoteFolderRef(logicalPath: folder.logicalPath, remoteId: newPath, displayPath: newPath)
        if oldName == newName { return folder }
        return try withRoot { root in
            let parent = try parentDirectory(root, RemoteFolderRef(logicalPath: folder.logicalPath, remoteId: parentPath, displayPath: parentPath))
            guard let old = try parent.status(oldName) else {
                // A previous attempt may have renamed it already (crash before the commit).
                if let moved = try parent.status(newName), moved.isDirectory { return renamed }
                throw DestinationError.folderMissing(logicalPath: folder.logicalPath)
            }
            if old.isSymlink { throw DestinationError.itemRejected(reason: "symlink") }
            guard old.isDirectory else { throw DestinationError.foreignFile }
            try parent.renameExclusive(oldName, to: newName, in: parent, allowCheckThenRename: true)
            return renamed
        }
    }

    // MARK: Probe and list

    func probe(_ path: String) throws -> RemoteItem? {
        if path.isEmpty { return RemoteItem(remoteId: "", name: "", parentIds: [], kind: .folder, relativePath: "") }
        try LocalPath.requireUserPath(path)
        let (parentPath, name) = try LocalPath.split(path)
        return try withRoot { root in
            let parent: DirectoryHandle
            do { parent = try root.openDirectory(parentPath) } catch DestinationError.notFound { return nil }
            guard let st = try parent.status(name) else { return nil }
            if st.isSymlink { throw DestinationError.itemRejected(reason: "symlink") }
            return try item(st, path: path)
        }
    }

    /// Depth-first walk of the tree below `path` (the whole root when empty). Skips `.photovault`, never
    /// follows symlinks, and skips mount points.
    func walk(under path: String, yield: @Sendable (RemoteItem) -> Void) throws {
        try withRoot { root in
            let start = path.isEmpty ? root : try userDirectory(root, path)
            try walkDirectory(start, path: path, yield: yield)
        }
    }

    private func walkDirectory(_ dir: DirectoryHandle, path: String, yield: @Sendable (RemoteItem) -> Void) throws {
        for name in try dir.entries().sorted() {
            if Task.isCancelled { return }
            if path.isEmpty, name == LocalPath.reservedDirectory || name == LocalPath.connectionTestName { continue }
            guard let st = try dir.status(name) else { continue }
            let child = LocalPath.join(path, name)
            if st.isDirectory {
                let handle: DirectoryHandle
                do { handle = try dir.openChild(name, create: false) } catch DestinationError.itemRejected { continue }
                yield(try item(st, path: child))
                try walkDirectory(handle, path: child, yield: yield)
            } else if st.isRegular {
                yield(try item(st, path: child))
            }
        }
    }

    /// SHA-256 of a regular file, nil when it does not exist. Used by the engine for verification.
    func contentHash(_ path: String) throws -> String? {
        try LocalPath.requireUserPath(path)
        let (parentPath, name) = try LocalPath.split(path)
        return try withRoot { root in
            let parent: DirectoryHandle
            do { parent = try root.openDirectory(parentPath) } catch DestinationError.notFound { return nil }
            guard try parent.status(name) != nil else { return nil }
            let fd = try parent.openFile(name)
            defer { close(fd) }
            return try FileHashing.sha256(fd: fd).hex
        }
    }
}
