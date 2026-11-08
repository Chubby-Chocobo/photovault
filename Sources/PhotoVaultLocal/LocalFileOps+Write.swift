import Darwin
import Foundation
import PhotoVaultCore

extension LocalFileOps {
    private enum Existing {
        case none
        case same(size: Int64)
        case different
    }

    private func inspect(_ dir: DirectoryHandle, _ name: String, expected: String) throws -> Existing {
        guard let st = try dir.status(name) else { return .none }
        if st.isSymlink { throw DestinationError.itemRejected(reason: "symlink") }
        guard st.isRegular else { throw DestinationError.foreignFile }
        let fd = try dir.openFile(name)
        defer { close(fd) }
        let hash = try FileHashing.sha256(fd: fd)
        return hash.hex == expected ? .same(size: hash.size) : .different
    }

    /// SHA-256 of the file now at `name`; nil when it vanished.
    private func currentHash(_ dir: DirectoryHandle, _ name: String) throws -> String? {
        guard try dir.status(name) != nil else { return nil }
        let fd = try dir.openFile(name)
        defer { close(fd) }
        return try FileHashing.sha256(fd: fd).hex
    }

    private func result(_ parent: String, _ name: String, hash: String, size: Int64) -> UploadResult {
        UploadResult(remoteId: LocalPath.join(parent, name), finalName: name, verifiedHash: hash, parentIds: [parent],
                     trashed: false, size: size)
    }

    // MARK: New files (never overwrite)

    func upload(_ request: UploadRequest, allowFallback: Bool) throws -> UploadResult {
        try LocalPath.validate(name: request.fileName)
        let expected = request.content.sha256
        return try withRoot { root in
            let parent = try parentDirectory(root, request.parent)
            try requireFallbackIfNeeded(parent.device, allowFallback: allowFallback)
            let parentPath = request.parent.remoteId
            let tmp = try tmpDirectory(root, create: true)
            var part: String?
            defer { if let part { writer.discard(part, in: tmp) } }

            for _ in 0..<3 {
                var target = request.fileName
                switch try inspect(parent, target, expected: expected) {
                case .same(let size): return result(parentPath, target, hash: expected, size: size)
                case .none: break
                case .different:
                    // Someone else's file owns the name: only originals may take a conflict name (FR-73).
                    guard request.kind == .original else { throw DestinationError.foreignFile }
                    target = LocalPath.conflictName(target, sha256: expected)
                    switch try inspect(parent, target, expected: expected) {
                    case .same(let size): return result(parentPath, target, hash: expected, size: size)
                    case .none: break
                    case .different: throw DestinationError.foreignFile
                    }
                }
                if part == nil { part = try writer.stage(.file(request.content.file), expectedSHA256: expected, in: tmp) }
                do {
                    try tmp.renameExclusive(part!, to: target, in: parent, allowCheckThenRename: allowFallback, memo: renameMemo)
                    parent.sync()
                    return result(parentPath, target, hash: expected, size: request.content.size)
                } catch DestinationError.foreignFile {
                    continue  // lost a race for the name: look at what is there now
                }
            }
            throw DestinationError.foreignFile
        }
    }

    // MARK: Replacing the app's own files

    /// Replaces an edited/sidecar file, only when its current hash is the one the app last wrote.
    func replace(path: String, _ request: UploadRequest) throws -> UploadResult {
        try LocalPath.requireUserPath(path)
        let (parentPath, name) = try LocalPath.split(path)
        let expected = request.content.sha256
        return try withRoot { root in
            let parent = try root.openDirectory(parentPath)
            switch try inspect(parent, name, expected: expected) {
            case .none: throw DestinationError.notFound
            case .same(let size): return result(parentPath, name, hash: expected, size: size)
            case .different: break
            }
            guard let prior = request.expectedPriorHash, try currentHash(parent, name) == prior else {
                throw DestinationError.foreignModified
            }
            let tmp = try tmpDirectory(root, create: true)
            let part = try writer.stage(.file(request.content.file), expectedSHA256: expected, in: tmp)
            defer { writer.discard(part, in: tmp) }
            afterStaging?()
            // Staging can take minutes: look at the file again right before it is replaced (caller holds the write lock).
            guard try currentHash(parent, name) == prior else { throw DestinationError.foreignModified }
            try tmp.renameReplacing(part, to: name, in: parent)
            parent.sync()
            return result(parentPath, name, hash: expected, size: request.content.size)
        }
    }

    // MARK: Move

    func move(path: String, name: String, to: RemoteFolderRef, allowFallback: Bool) throws -> RemoteItem {
        try LocalPath.validate(name: name)
        try LocalPath.requireUserPath(path)
        let (sourceParent, sourceName) = try LocalPath.split(path)
        let target = LocalPath.join(to.remoteId, name)
        return try withRoot { root in
            let destination = try parentDirectory(root, to)
            let source = try root.openDirectory(sourceParent)
            try requireFallbackIfNeeded(destination.device, allowFallback: allowFallback)
            guard let st = try source.status(sourceName) else {
                // A previous attempt may already have moved it.
                if let moved = try destination.status(name), moved.isRegular { return try item(moved, path: target) }
                throw DestinationError.notFound
            }
            if st.isSymlink { throw DestinationError.itemRejected(reason: "symlink") }
            guard st.isRegular else { throw DestinationError.itemRejected(reason: "not a regular file") }
            try source.renameExclusive(sourceName, to: name, in: destination, allowCheckThenRename: allowFallback, memo: renameMemo)
            guard let placed = try destination.status(name) else { throw DestinationError.notFound }
            return try item(placed, path: target)
        }
    }
}
