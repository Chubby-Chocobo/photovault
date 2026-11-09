import Darwin
import Foundation
import PhotoVaultCore

/// A folder the owner picked, read once to import its photos. Everything is read-only: files open
/// `O_RDONLY` and this type has no create, rename or delete call. Errors are `SourceError`.
public final class LocalFolderSource: FolderImportSource, Sendable {
    public let id: SourceID
    let root: any RootAccess
    let metadata: any FileMetadataReading
    /// Serial: listing, hashing and copying never occupy the Swift concurrency pool.
    let queue: BlockingQueue

    static let chunkSize = 1 << 20

    public init(id: SourceID, root: any RootAccess, metadata: any FileMetadataReading) {
        self.id = id
        self.root = root
        self.metadata = metadata
        self.queue = BlockingQueue(label: "photovault.source.\(id.rawValue)")
    }

    public func probe() async throws {
        let root = root
        try await queue.run {
            try Self.withFolder(root) { _ in }
        }
    }

    public func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        let root = root
        let metadata = metadata
        return try await queue.run {
            try Self.withFolder(root) { folder in
                let (fd, url) = try Self.openFile(folder, relativePath)
                defer { close(fd) }
                let (digest, size) = try Self.stream(fd, folder: folder, control: control) { _ in }
                return InspectedFile(size: size, sha256: digest, metadata: metadata.fileMetadata(of: url, uti: uti, mediaType: mediaType))
            }
        }
    }

    public func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        guard let primary = ImportLocator(localId: locator.localId), primary.sourceId == id else { throw SourceError.fileMissing }
        let relativePath = primary.sibling(named: locator.originalFilename)
        let root = root
        return try await queue.run {
            try Self.withFolder(root) { folder in
                let (fd, _) = try Self.openFile(folder, relativePath)
                defer { close(fd) }
                let writer: StreamingFileWriter
                do {
                    writer = try StreamingFileWriter(url: destination, control: control)
                } catch let failure as StreamingFileWriter.Failure {
                    throw Self.map(failure)
                }
                do {
                    // The writer reports the bytes to `control` itself.
                    _ = try Self.stream(fd, folder: folder, control: nil) { chunk in
                        if !writer.append(chunk) { throw writer.failure.map(Self.map) ?? SourceError.cancelled }
                    }
                    return try writer.finish()
                } catch let failure as StreamingFileWriter.Failure {
                    writer.abort()
                    throw Self.map(failure)
                } catch {
                    writer.abort()
                    throw error
                }
            }
        }
    }

    // MARK: Reading

    /// Opens the folder; anything that stops it from opening means the source cannot be reached now.
    static func withFolder<T>(_ root: any RootAccess, _ body: (URL) throws -> T) throws -> T {
        do {
            return try root.withRoot { folder in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw SourceError.unavailable
                }
                return try body(folder)
            }
        } catch let error as SourceError {
            throw error
        } catch is DestinationError {
            throw SourceError.unavailable
        }
    }

    /// File under `folder`; a path that climbs out of it names nothing.
    static func fileURL(_ folder: URL, _ relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { throw SourceError.fileMissing }
        return parts.reduce(folder) { $0.appendingPathComponent(String($1)) }
    }

    /// Opens read-only. Names are kept normalised (NFC) in the database; a volume that stores another
    /// spelling is found by looking the name up in its directory.
    static func openFile(_ folder: URL, _ relativePath: String) throws -> (fd: Int32, url: URL) {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        var url = try fileURL(folder, relativePath)
        var fd = open(url.path, flags)
        if fd < 0, errno == ENOENT, let real = onDiskURL(folder, relativePath) {
            url = real
            fd = open(url.path, flags)
        }
        guard fd >= 0 else { throw map(errno: errno, folder: folder) }
        return (fd, url)
    }

    /// The file as the volume spells it, found by comparing normalised names; nil when it is not there.
    static func onDiskURL(_ folder: URL, _ relativePath: String) -> URL? {
        var current = folder
        for part in relativePath.split(separator: "/") {
            let wanted = String(part).precomposedStringWithCanonicalMapping
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                  let match = names.first(where: { $0.precomposedStringWithCanonicalMapping == wanted }) else { return nil }
            current = current.appendingPathComponent(match)
        }
        return current
    }

    /// Streams the open file in chunks through SHA-256, passing each chunk to `sink`. Reports the bytes
    /// to `control`, when given.
    static func stream(_ fd: Int32, folder: URL, control: ExportControl?, sink: (Data) throws -> Void) throws -> (sha256: String, size: Int64) {
        var hasher = StreamingSHA256()
        var size: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw map(errno: errno, folder: folder)
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            try sink(Data(buffer[0..<count]))
            size += Int64(count)
            if let control, !control.record(bytes: count) { throw SourceError.cancelled }
        }
        return (hasher.finish(), size)
    }

    static func map(errno code: Int32, folder: URL) -> SourceError {
        switch code {
        case ENOENT, ENOTDIR:
            // A vanished folder (unplugged disk) looks like a missing file; tell them apart.
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) ? .fileMissing : .unavailable
        case ENXIO, ENODEV, EIO, ETIMEDOUT, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ESTALE:
            // One file that cannot be read is that file's problem while the folder still answers.
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? .readFailed(code: Int(code)) : .unavailable
        default: return .readFailed(code: Int(code))
        }
    }

    static func map(_ failure: StreamingFileWriter.Failure) -> SourceError {
        switch failure {
        case .stopped: .cancelled
        case .io(let code, _): .readFailed(code: code)
        }
    }
}
