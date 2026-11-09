import Foundation
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
@testable import PhotoVaultEngine

/// A stand-in for a cloud adapter: it serves a tree from disk but is a different type from the Mac
/// folder adapter, and can answer "the grant was revoked" for each call.
final class FakeCloudSource: FolderImportSource, @unchecked Sendable {
    struct Revoked: OptionSet, Sendable {
        let rawValue: Int
        static let probe = Revoked(rawValue: 1)
        static let list = Revoked(rawValue: 2)
        static let inspect = Revoked(rawValue: 4)
        static let export = Revoked(rawValue: 8)
        static let all: Revoked = [.probe, .list, .inspect, .export]
    }

    private let inner: LocalFolderSource
    private let lock = NSLock()
    private var revoked: Revoked = []
    var id: SourceID { inner.id }

    init(_ folder: ImportFolder) { inner = folder.source() }

    func setRevoked(_ value: Revoked) { lock.withLock { revoked = value } }
    private func check(_ call: Revoked) throws { if lock.withLock({ revoked.contains(call) }) { throw SourceError.accessRevoked } }

    func probe() async throws { try check(.probe); try await inner.probe() }
    func listFiles() async throws -> [FolderFileEntry] { try check(.list); return try await inner.listFiles() }
    func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        try check(.inspect)
        return try await inner.inspect(relativePath: relativePath, uti: uti, mediaType: mediaType, control: control)
    }
    func exportResource(_ l: ResourceLocator, to d: URL, control: ExportControl) async throws -> ExportedFile {
        try check(.export)
        return try await inner.exportResource(l, to: d, control: control)
    }
}

extension Harness {
    /// Starts an import of the given kind through `source` and settles the cycle.
    @discardableResult
    func startCloudImport(
        _ source: any FolderImportSource, kind: SourceKind = .dropbox, account: String? = "someone@example.com", settle rounds: Int = 6
    ) async throws -> SourceID {
        let id = try await coordinator.startImport(
            source: source, kind: kind, displayName: "Trip", config: SourceConfig(account: account, remoteItems: [""]))
        await settle(rounds: rounds)
        return id
    }
}
