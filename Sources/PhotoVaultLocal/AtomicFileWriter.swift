import Darwin
import Foundation
import PhotoVaultCore

/// Stages content into `.photovault/tmp/<UUID>.part`, flushes it to stable storage and verifies it by
/// reading it back. Placing the result is left to `DirectoryHandle` so the caller picks the policy.
final class AtomicFileWriter: Sendable {
    enum Source {
        case file(URL)
        case data(Data)
    }

    /// `.part` files being written by this process; the orphan sweep must not touch them.
    private let active = ActiveParts()

    func isActive(_ name: String) -> Bool { active.contains(name) }

    /// Returns the name of a fully written, synced and read-back-verified `.part` in `tmp`. Removes the
    /// `.part` itself on any failure. The caller must `discard` it after placing or giving up.
    func stage(_ source: Source, expectedSHA256: String, in tmp: DirectoryHandle) throws -> String {
        let name = UUID().uuidString + ".part"
        let out = try tmp.createExclusive(name)
        active.insert(name)
        var succeeded = false
        defer {
            if !succeeded { discard(name, in: tmp) }
        }
        do {
            let written = try copy(source, to: out)
            guard written == expectedSHA256 else { throw DestinationError.checksumMismatch(expected: expectedSHA256, actual: written) }
            try flush(out)
        } catch {
            close(out)
            throw error
        }
        guard close(out) == 0 else { throw ErrorClassifier.destinationError(errno: errno) }
        let readBack = try tmp.openFile(name)
        defer { close(readBack) }
        let verified = try FileHashing.sha256(fd: readBack).hex
        guard verified == expectedSHA256 else { throw DestinationError.checksumMismatch(expected: expectedSHA256, actual: verified) }
        succeeded = true
        return name
    }

    /// Removes our own `.part` (idempotent). Failure to remove is not fatal: the orphan sweep retries.
    func discard(_ name: String, in tmp: DirectoryHandle) {
        try? tmp.unlinkOwned(name)
        active.remove(name)
    }

    private func copy(_ source: Source, to out: Int32) throws -> String {
        switch source {
        case .data(let data):
            try data.withUnsafeBytes { try FileHashing.writeAll(fd: out, $0) }
            return FileHashing.sha256(data)
        case .file(let url):
            let input = open(url.path, O_RDONLY | O_CLOEXEC)
            guard input >= 0 else { throw ErrorClassifier.destinationError(errno: errno) }
            defer { close(input) }
            return try copyAndHash(from: input, to: out)
        }
    }

    private func copyAndHash(from input: Int32, to out: Int32) throws -> String {
        var hasher = StreamingSHA256()
        var buffer = [UInt8](repeating: 0, count: FileHashing.chunkSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ErrorClassifier.destinationError(errno: errno)
            }
            if n == 0 { return hasher.finish() }
            try buffer.withUnsafeBytes {
                let chunk = UnsafeRawBufferPointer(rebasing: $0.prefix(n))
                hasher.update(chunk)
                try FileHashing.writeAll(fd: out, chunk)
            }
        }
    }

    /// `F_FULLFSYNC`; filesystems without it (`ENOTSUP`, SMB) fall back to `fsync`.
    private func flush(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard [ENOTSUP, ENOTTY, EINVAL].contains(errno) else { throw ErrorClassifier.destinationError(errno: errno) }
        guard fsync(fd) == 0 else { throw ErrorClassifier.destinationError(errno: errno) }
    }
}

private final class ActiveParts: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    func insert(_ name: String) { lock.withLock { _ = names.insert(name) } }
    func remove(_ name: String) { lock.withLock { _ = names.remove(name) } }
    func contains(_ name: String) -> Bool { lock.withLock { names.contains(name) } }
}
