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
    private var failures: [Int: any Error] = [:]
    private var oneShots: [Int: any Error] = [:]
    private var pathFailures: [String: any Error] = [:]
    private var sizes: [String: Int64] = [:]
    private var probeCalls = 0
    var id: SourceID { inner.id }

    init(_ folder: ImportFolder) { inner = folder.source() }

    func setRevoked(_ value: Revoked) { lock.withLock { revoked = value } }
    /// Makes one call throw `error` (nil clears it); takes precedence over `setRevoked`.
    func setFailure(_ call: Revoked, _ error: (any Error)?) { lock.withLock { failures[call.rawValue] = error } }
    /// Makes the next call throw `error`, once.
    func failOnce(_ call: Revoked, _ error: any Error) { lock.withLock { oneShots[call.rawValue] = error } }
    /// Makes every read of `path` throw `error` (nil clears it).
    func setFailure(path: String, _ error: (any Error)?) { lock.withLock { pathFailures[path] = error } }
    /// Lists `path` with a different size, as a huge file would be.
    func setSize(of path: String, _ bytes: Int64) { lock.withLock { sizes[path] = bytes } }
    var probeCount: Int { lock.withLock { probeCalls } }
    private func check(_ call: Revoked) throws {
        if let error = lock.withLock({ oneShots.removeValue(forKey: call.rawValue) }) { throw error }
        if let error = lock.withLock({ failures[call.rawValue] }) { throw error }
        if lock.withLock({ revoked.contains(call) }) { throw SourceError.accessRevoked }
    }

    func probe() async throws {
        lock.withLock { probeCalls += 1 }
        try check(.probe)
        try await inner.probe()
    }
    func listFiles() async throws -> [FolderFileEntry] {
        try check(.list)
        return try await inner.listFiles().map { entry in
            guard let size = lock.withLock({ sizes[entry.relativePath] }) else { return entry }
            var entry = entry
            entry.sizeBytes = size
            return entry
        }
    }
    func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        try check(.inspect)
        if let error = lock.withLock({ pathFailures[relativePath] }) { throw error }
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

/// Counts every export call the engine makes against one content source.
final class CountingContentSource: ContentSource, @unchecked Sendable {
    private let inner: FakeContentSource
    private let lock = NSLock()
    private var count = 0
    init(_ inner: FakeContentSource) { self.inner = inner }
    var id: SourceID { inner.id }
    var calls: Int { lock.withLock { count } }
    func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        lock.withLock { count += 1 }
        return try await inner.exportResource(locator, to: destination, control: control)
    }
}
