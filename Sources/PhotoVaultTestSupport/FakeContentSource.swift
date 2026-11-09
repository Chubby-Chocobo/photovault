import Foundation
import PhotoVaultCore

/// A non-Photos content source with in-memory files. Throws `SourceError.unavailable` while offline.
public final class FakeContentSource: ContentSource, @unchecked Sendable {
    public let id: SourceID
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var online = true
    private var revoked = false
    private var exportLog: [String] = []

    public init(id: SourceID = .folder()) { self.id = id }

    private static func key(_ localId: String, _ type: ResourceType) -> String { "\(localId)|\(type.rawValue)" }

    public func add(localId: String, type: ResourceType = .photo, data: Data) {
        lock.withLock { files[Self.key(localId, type)] = data }
    }

    public func setOnline(_ value: Bool) { lock.withLock { online = value } }

    /// The provider rejects the stored grant: every read throws `accessRevoked`.
    public func setRevoked(_ value: Bool) { lock.withLock { revoked = value } }

    /// Local ids exported so far, in order.
    public var exportedLocalIds: [String] { lock.withLock { exportLog } }

    public func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        let bytes: Data = try lock.withLock {
            guard !revoked else { throw SourceError.accessRevoked }
            guard online else { throw SourceError.unavailable }
            guard let data = files[Self.key(locator.localId, locator.type)] else { throw SourceError.fileMissing }
            exportLog.append(locator.localId)
            return data
        }
        guard control.record(bytes: bytes.count) else { throw SourceError.cancelled }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination)
        let hashes = TestFiles.hashes(of: bytes)
        return ExportedFile(url: destination, size: Int64(bytes.count), md5: hashes.md5, sha256: hashes.sha256)
    }
}
