import Darwin
import Foundation
import PhotoVaultCore

/// Synchronous, fd-relative file operations of a local destination. Holds no mutable state, so the
/// destination actor can run it under a folder lock off its own executor.
struct LocalFileOps: Sendable {
    let access: any RootAccess
    let writer: AtomicFileWriter
    let log: any LogSink
    let renameMemo: ExclusiveRenameMemo
    /// Test seam: runs after the new content is staged and before it is put in place.
    var afterStaging: (@Sendable () -> Void)?
    /// Test seam: receives the identity of every directory flushed after a namespace change.
    var onDirectorySync: (@Sendable (String) -> Void)?

    init(access: any RootAccess, writer: AtomicFileWriter, log: any LogSink,
         renameMemo: ExclusiveRenameMemo = .volumes, afterStaging: (@Sendable () -> Void)? = nil,
         onDirectorySync: (@Sendable (String) -> Void)? = nil) {
        self.access = access
        self.writer = writer
        self.log = log
        self.renameMemo = renameMemo
        self.afterStaging = afterStaging
        self.onDirectorySync = onDirectorySync
    }

    /// Flushes a directory so a rename or new entry in it survives power loss before success is reported.
    func flush(_ dir: DirectoryHandle) {
        dir.sync()
        onDirectorySync?(dir.identity)
    }

    /// Opens the root, retrying once with a fresh bookmark resolution when the cached path is gone: the
    /// owner may have renamed or moved the folder, which the bookmark follows.
    func withRoot<T>(_ body: (DirectoryHandle) throws -> T) throws -> T {
        do {
            return try withResolvedRoot(body)
        } catch let failure as RootOpenFailure {
            guard access.invalidateResolvedRoot() else { throw failure.underlying }
            do {
                return try withResolvedRoot(body)
            } catch let again as RootOpenFailure {
                throw again.underlying
            }
        }
    }

    /// The root could not be opened (the operation itself has not started, so repeating it is safe).
    private struct RootOpenFailure: Error { let underlying: DestinationError }

    private func withResolvedRoot<T>(_ body: (DirectoryHandle) throws -> T) throws -> T {
        try access.withRoot { url in
            let root: DirectoryHandle
            do {
                root = try DirectoryHandle.openRoot(url)
            } catch DestinationError.rootMissing {
                throw RootOpenFailure(underlying: .rootMissing)
            } catch DestinationError.offline {
                throw RootOpenFailure(underlying: .offline)
            }
            return try body(root)
        }
    }

    /// Before staging: a volume known to lack exclusive rename needs the write-locked path from the start.
    func requireFallbackIfNeeded(_ volume: VolumeKey, allowFallback: Bool) throws {
        if !allowFallback, renameMemo.isUnsupported(volume) { throw ExclusiveRenameUnsupported() }
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
            let existing = try parent.status(request.name)
            if let st = existing {
                if st.isSymlink { throw DestinationError.itemRejected(reason: "symlink") }
                guard st.isDirectory else { throw DestinationError.foreignFile }
            }
            _ = try parent.openChild(request.name, create: true)
            if existing == nil { flush(parent) }
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
            try parent.renameExclusive(oldName, to: newName, in: parent, allowCheckThenRename: true, memo: renameMemo)
            flush(parent)
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
            guard st.isRegular || st.isDirectory else { throw DestinationError.itemRejected(reason: "not a regular file") }
            return try item(st, path: path)
        }
    }

    /// Depth-first walk of the tree below `path` (the whole root when empty). Skips `.photovault`, never
    /// follows symlinks, and skips mount points.
    /// An entry that cannot be described (a name the app cannot address, a refused symlink or other
    /// volume) is skipped; any other failure aborts, so a short listing is never reported as complete.
    func walk(under path: String, isCancelled: @Sendable () -> Bool = { false }, yield: @Sendable (RemoteItem) -> Void) throws {
        try withRoot { root in
            let start = path.isEmpty ? root : try userDirectory(root, path)
            var skipped = 0
            try walkDirectory(start, path: path, isCancelled: isCancelled, skipped: &skipped, yield: yield)
            if skipped > 0 { log.log(.info, category: "local", "skipped \(skipped) unreadable entries while listing") }
        }
    }

    private func walkDirectory(_ dir: DirectoryHandle, path: String, isCancelled: @Sendable () -> Bool, skipped: inout Int,
                               yield: @Sendable (RemoteItem) -> Void) throws {
        for name in try dir.entries().sorted() {
            if isCancelled() { return }
            if path.isEmpty, name == LocalPath.reservedDirectory || name == LocalPath.connectionTestName { continue }
            let described: (item: RemoteItem, handle: DirectoryHandle?)?
            do {
                described = try describe(name, in: dir, path: path)
            } catch DestinationError.itemRejected {
                skipped += 1
                continue
            }
            guard let described else { continue }
            yield(described.item)
            if let handle = described.handle {
                try walkDirectory(handle, path: described.item.remoteId, isCancelled: isCancelled, skipped: &skipped, yield: yield)
            }
        }
    }

    /// The item for one directory entry plus a handle when it is a folder; nil for entries the walk ignores
    /// (vanished, special files).
    private func describe(_ name: String, in dir: DirectoryHandle, path: String) throws -> (item: RemoteItem, handle: DirectoryHandle?)? {
        guard let st = try dir.status(name) else { return nil }
        let child = LocalPath.join(path, name)
        if st.isDirectory {
            let handle = try dir.openChild(name, create: false)
            return (try item(st, path: child), handle)
        }
        return st.isRegular ? (try item(st, path: child), nil) : nil
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

    /// Bytes of a small file at `path` (relative, no symlinks followed); nil when it does not exist.
    /// Files larger than `maxBytes` throw `DestinationError.itemRejected` instead of being read.
    func readSmallFile(_ path: String, maxBytes: Int) throws -> Data? {
        try LocalPath.requireUserPath(path)
        let (parentPath, name) = try LocalPath.split(path)
        return try withRoot { root in
            let parent: DirectoryHandle
            do { parent = try root.openDirectory(parentPath) } catch DestinationError.notFound { return nil }
            guard let info = try parent.status(name) else { return nil }
            guard Int(info.st_size) <= maxBytes else { throw DestinationError.itemRejected(reason: "file too large") }
            let fd = try parent.openFile(name)
            defer { close(fd) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count < 0 { throw ErrorClassifier.destinationError(errno: errno) }
                if count == 0 { break }
                data.append(contentsOf: buffer[0..<count])
                guard data.count <= maxBytes else { throw DestinationError.itemRejected(reason: "file too large") }
            }
            return data
        }
    }
}
