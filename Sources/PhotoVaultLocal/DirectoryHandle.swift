import Darwin
import Foundation
import PhotoVaultCore

/// Thrown when `RENAME_EXCL` and `link()` are unsupported and only a check-then-rename is left;
/// the caller must retry under the folder write lock.
struct ExclusiveRenameUnsupported: Error {}

extension stat {
    var isRegular: Bool { (st_mode & S_IFMT) == S_IFREG }
    var isDirectory: Bool { (st_mode & S_IFMT) == S_IFDIR }
    var isSymlink: Bool { (st_mode & S_IFMT) == S_IFLNK }
}

/// An open directory descriptor. Every operation is relative to it, never follows symlinks and
/// stays on the volume of the root (`st_dev`). Immutable after init, so safe to share.
final class DirectoryHandle: @unchecked Sendable {
    private let fd: Int32
    let device: dev_t

    private init(fd: Int32, device: dev_t) {
        self.fd = fd
        self.device = device
    }

    deinit { close(fd) }

    private static func fail(_ code: Int32) -> DestinationError { ErrorClassifier.destinationError(errno: code) }

    /// Opens the root once. A missing root means the volume is not mounted.
    static func openRoot(_ url: URL) throws -> DirectoryHandle {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            throw (code == ENOENT || code == ENOTDIR) ? DestinationError.offline : fail(code)
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let code = errno
            close(fd)
            throw fail(code)
        }
        return DirectoryHandle(fd: fd, device: st.st_dev)
    }

    // MARK: Traversal

    /// Resolves each component with `openat(O_NOFOLLOW|O_DIRECTORY)`; an empty path returns `self`.
    func openDirectory(_ relative: String, create: Bool = false) throws -> DirectoryHandle {
        var current = self
        for name in try LocalPath.components(relative) { current = try current.openChild(name, create: create) }
        return current
    }

    func openChild(_ name: String, create: Bool) throws -> DirectoryHandle {
        try LocalPath.validate(name: name)
        if create, mkdirat(fd, name, 0o755) != 0, errno != EEXIST { throw Self.fail(errno) }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            let code = errno
            if let st = try? status(name), st.isSymlink { throw DestinationError.itemRejected(reason: "symlink") }
            throw Self.fail(code)
        }
        var st = stat()
        guard fstat(child, &st) == 0 else {
            let code = errno
            close(child)
            throw Self.fail(code)
        }
        guard st.st_dev == device else {
            close(child)
            throw DestinationError.itemRejected(reason: "other volume")
        }
        return DirectoryHandle(fd: child, device: device)
    }

    /// `fstatat(AT_SYMLINK_NOFOLLOW)`; nil when the entry does not exist.
    func status(_ name: String) throws -> stat? {
        try LocalPath.validate(name: name)
        var st = stat()
        if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { return st }
        if errno == ENOENT { return nil }
        throw Self.fail(errno)
    }

    func entries() throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw Self.fail(errno) }
        guard let dir = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw Self.fail(code)
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    // MARK: Files

    /// Opens a regular file for reading; refuses symlinks and non-regular files.
    func openFile(_ name: String) throws -> Int32 {
        try LocalPath.validate(name: name)
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Self.fail(errno) }
        var st = stat()
        guard fstat(file, &st) == 0, st.isRegular else {
            close(file)
            throw DestinationError.itemRejected(reason: "not a regular file")
        }
        return file
    }

    /// Creates a new file; fails with `foreignFile` if the name exists (never truncates).
    func createExclusive(_ name: String) throws -> Int32 {
        try LocalPath.validate(name: name)
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw Self.fail(errno) }
        return file
    }

    func sync() {
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
    }

    // MARK: Deletion (the only one in the module)

    /// Name of a temp file this module creates: `<UPPERCASE UUID>.part`.
    static func isOwnedPartName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 41, name.hasSuffix(".part") else { return false }
        return bytes.prefix(36).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || $0 == 0x2D }
    }

    /// Removes a temp `.part` or the `.photovault-test` file. Refuses every other name, so no code
    /// path can delete backup data. A missing entry is not an error.
    func unlinkOwned(_ name: String) throws {
        guard Self.isOwnedPartName(name) || name == LocalPath.connectionTestName else {
            throw DestinationError.itemRejected(reason: "not deletable")
        }
        if unlinkat(fd, name, 0) != 0, errno != ENOENT { throw Self.fail(errno) }
    }

    // MARK: Placement

    /// Renames without overwriting: `RENAME_EXCL`, else `linkat` + removal of the `.part`, else (only when
    /// `allowCheckThenRename`, i.e. the caller holds the folder write lock) check-then-rename.
    func renameExclusive(_ from: String, to name: String, in destination: DirectoryHandle, allowCheckThenRename: Bool) throws {
        try LocalPath.validate(name: from)
        try LocalPath.validate(name: name)
        if renameatx_np(fd, from, destination.fd, name, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard [ENOTSUP, EINVAL, ENOSYS].contains(code) else { throw Self.fail(code) }
        if Self.isOwnedPartName(from) {
            if linkat(fd, from, destination.fd, name, 0) == 0 {
                try? unlinkOwned(from)
                return
            }
            let linkCode = errno
            guard [ENOTSUP, EPERM, EMLINK, EINVAL, ENOSYS].contains(linkCode) else { throw Self.fail(linkCode) }
        }
        guard allowCheckThenRename else { throw ExclusiveRenameUnsupported() }
        guard try destination.status(name) == nil else { throw Self.fail(EEXIST) }
        guard renameat(fd, from, destination.fd, name) == 0 else { throw Self.fail(errno) }
    }

    /// Atomically replaces `name` with the verified `.part`. Callers must have checked the content
    /// currently at `name` is the app's own (hash equals the expected prior hash).
    func renameReplacing(_ part: String, to name: String, in destination: DirectoryHandle) throws {
        guard Self.isOwnedPartName(part) else { throw DestinationError.itemRejected(reason: "not a temp file") }
        try LocalPath.validate(name: name)
        guard renameat(fd, part, destination.fd, name) == 0 else { throw Self.fail(errno) }
    }
}
