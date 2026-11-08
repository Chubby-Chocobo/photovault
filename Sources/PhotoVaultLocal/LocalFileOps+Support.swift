import Darwin
import Foundation
import PhotoVaultCore

extension LocalFileOps {
    // MARK: Availability

    /// Verifies the root is reachable and removes orphaned `.part` files from `.photovault/tmp`.
    /// Only names matching `^[0-9A-F-]{36}\.part$` that this process is not writing are removed.
    func checkRootAndSweep() throws {
        try withRoot { root in
            let tmp: DirectoryHandle
            do { tmp = try tmpDirectory(root, create: false) } catch DestinationError.notFound { return }
            var removed = 0
            for name in try tmp.entries() where DirectoryHandle.isOwnedPartName(name) && !writer.isActive(name, in: tmp) {
                guard let st = try tmp.status(name), st.isRegular else { continue }
                try tmp.unlinkOwned(name)
                removed += 1
            }
            if removed > 0 { log.log(.info, category: "local", "removed \(removed) orphaned temp files") }
        }
    }

    /// Write, read back and delete `.photovault-test` at the root (FR-70).
    func testConnection() throws {
        try withRoot { root in
            try root.unlinkOwned(LocalPath.connectionTestName)  // leftover from a crashed run
            let payload = Data(UUID().uuidString.utf8)
            let fd = try root.createExclusive(LocalPath.connectionTestName)
            defer { try? root.unlinkOwned(LocalPath.connectionTestName) }
            do {
                try payload.withUnsafeBytes { try FileHashing.writeAll(fd: fd, $0) }
                guard fsync(fd) == 0 else { throw ErrorClassifier.destinationError(errno: errno) }
            } catch {
                close(fd)
                throw error
            }
            close(fd)
            let readFd = try root.openFile(LocalPath.connectionTestName)
            defer { close(readFd) }
            guard try FileHashing.sha256(fd: readFd).hex == FileHashing.sha256(payload) else {
                throw DestinationError.checksumMismatch(expected: FileHashing.sha256(payload), actual: "read-back")
            }
        }
    }

    // MARK: destination.json

    private func readMarker(in support: DirectoryHandle) throws -> DestinationMarker? {
        guard let st = try support.status(LocalPath.markerName) else { return nil }
        // An unreadable marker is treated as foreign: it is never overwritten.
        guard st.isRegular, st.st_size <= 1 << 20 else { throw DestinationError.foreignFile }
        let fd = try support.openFile(LocalPath.markerName)
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ErrorClassifier.destinationError(errno: errno)
            }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
        }
        guard let marker = try? DestinationMarker.decoder().decode(DestinationMarker.self, from: data) else {
            throw DestinationError.foreignFile
        }
        return marker
    }

    func readMarker() throws -> DestinationMarker? {
        try withRoot { root in
            let support: DirectoryHandle
            do { support = try root.openDirectory(LocalPath.reservedDirectory) } catch DestinationError.notFound { return nil }
            return try readMarker(in: support)
        }
    }

    /// Writes the marker unless one exists. An existing marker with the same id is returned unchanged;
    /// one with another id (or unreadable) throws `foreignFile`.
    func writeMarker(_ marker: DestinationMarker, allowFallback: Bool) throws -> DestinationMarker {
        try withRoot { root in
            let support = try root.openDirectory(LocalPath.reservedDirectory, create: true)
            try requireFallbackIfNeeded(support.volume, allowFallback: allowFallback)
            func existingOrNil() throws -> DestinationMarker? {
                guard let existing = try readMarker(in: support) else { return nil }
                guard existing.id == marker.id else { throw DestinationError.foreignFile }
                return existing
            }
            if let existing = try existingOrNil() { return existing }
            let data = try DestinationMarker.encoder().encode(marker)
            let tmp = try tmpDirectory(root, create: true)
            let part = try writer.stage(.data(data), expectedSHA256: FileHashing.sha256(data), in: tmp)
            defer { writer.discard(part, in: tmp) }
            do {
                try tmp.renameExclusive(part, to: LocalPath.markerName, in: support, allowCheckThenRename: allowFallback, memo: renameMemo)
            } catch DestinationError.foreignFile {
                if let existing = try existingOrNil() { return existing }
                throw DestinationError.foreignFile
            }
            support.sync()
            return marker
        }
    }
}
