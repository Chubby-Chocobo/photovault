import Foundation
import PhotoVaultCore

/// File metadata answered from a table keyed by a path relative to the folder (or just a file name);
/// the longest key that ends the file's path wins, and unknown files read as empty.
public final class StubFileMetadataReader: FileMetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: FileMetadata] = [:]

    public init() {}

    public func set(_ relativePath: String, _ metadata: FileMetadata) { lock.withLock { table[relativePath] = metadata } }

    public func fileMetadata(of file: URL, uti: String, mediaType: MediaType) -> FileMetadata {
        lock.withLock {
            let match = table.keys.filter { file.path == $0 || file.path.hasSuffix("/" + $0) }.max { $0.count < $1.count }
            return match.flatMap { table[$0] } ?? .empty
        }
    }
}
