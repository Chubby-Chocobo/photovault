import CryptoKit
import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Generation-named staging files (spec 8.9.3): `<staging>/<sha256(assetKey) prefix>/<resType>.<gen>`;
/// sidecars, whose bytes differ per destination, add a destination tag: `<resType>.<tag>.<gen>`.
/// A file is released when no available destination still needs it and no transfer reads it, or
/// when it sat idle for two hours. A file an upload is reading is never deleted: leases and
/// releases are decided inside this actor, a release marks the file first and a lease on a file
/// being released is refused, so the check and the unlink cannot be separated by a new lease. The database row
/// is updated before the file is removed, so a crash leaves an orphan file (swept at startup),
/// never a row pointing at a missing file.
public actor StagingManager {
    private let env: EngineEnvironment
    private var leases: [String: Int] = [:]
    private var releasing: Set<String> = []

    init(env: EngineEnvironment) { self.env = env }

    nonisolated func fileURL(assetKey: AssetKey, type: ResourceType, generation: Int, destination: DestinationID? = nil) -> URL {
        let prefix = assetKey.sha256Hex.prefix(32)
        let name = destination.map { "\(type.rawValue).\(Self.tag($0)).\(generation)" } ?? "\(type.rawValue).\(generation)"
        return env.stagingDirectory
            .appendingPathComponent(String(prefix), isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    /// Short, path-safe tag of a destination id.
    private nonisolated static func tag(_ id: DestinationID) -> String {
        String(SHA256.hash(data: Data(id.rawValue.utf8)).hexString.prefix(8))
    }

    /// The staging file of an upload job: sidecars are per destination, resources are shared.
    nonisolated func fileURL(of job: UploadJob, generation: Int) -> URL {
        fileURL(assetKey: job.assetKey, type: job.resType, generation: generation, destination: job.resType.isSidecar ? job.destinationId : nil)
    }

    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    // MARK: Leases

    /// Marks a staged file as being read by a transfer. Returns false while the file is being
    /// released: the caller treats the staging as lost.
    @discardableResult
    func lease(_ path: String) -> Bool {
        let key = Self.canonical(path)
        guard !releasing.contains(key) else { return false }
        leases[key, default: 0] += 1
        return true
    }

    func unlease(_ path: String) {
        let key = Self.canonical(path)
        guard let count = leases[key] else { return }
        if count <= 1 { leases[key] = nil } else { leases[key] = count - 1 }
    }

    func isLeased(_ path: String) -> Bool { leases[Self.canonical(path)] != nil }
    /// True between the release's "nobody needs it" check and the end of its database write and unlink.
    func isReleasing(_ path: String) -> Bool { releasing.contains(Self.canonical(path)) }
    var activeTransfers: Int { leases.values.reduce(0, +) }

    // MARK: Sizes

    func stagedBytes() async throws -> Int64 { try await env.store.read { db in try EngineQueries.stagedBytes(db) } }

    // MARK: Release

    /// Releases staged files nobody needs. `asset` limits the sweep to one asset's resources.
    @discardableResult
    func releaseUnneeded(asset: AssetKey? = nil) async throws -> Int {
        let ready = try await env.store.read { db in try ResourceRepository.fetch(db, stagingState: .ready, limit: Int.max) }
        var released = 0
        for resource in ready where asset == nil || resource.assetKey == asset {
            guard let path = resource.stagingPath, !isLeased(path) else { continue }
            if try await release(resource, onlyIfUnneeded: true) { released += 1 }
        }
        return released
    }

    /// Releases files untouched for the idle period even if a (waiting) job still wants them.
    @discardableResult
    func expireIdle() async throws -> Int {
        let cutoff = env.clock.now.addingTimeInterval(-env.tuning.stagingIdleExpiry)
        let ready = try await env.store.read { db in try ResourceRepository.fetch(db, stagingState: .ready, limit: Int.max) }
        var released = 0
        for resource in ready {
            guard let path = resource.stagingPath, !isLeased(path) else { continue }
            guard (resource.lastUsedAt ?? .distantPast) < cutoff else { continue }
            if try await release(resource, onlyIfUnneeded: false) { released += 1 }
        }
        return released
    }

    /// Row first, file second. The path is marked as `releasing` before the first suspension, so a
    /// lease taken meanwhile is refused; a lease taken before is seen here and stops the release.
    /// `onlyIfUnneeded` repeats the "nobody needs it" check inside the same transaction as the update.
    private func release(_ resource: ResourceRecord, onlyIfUnneeded: Bool) async throws -> Bool {
        let key = resource.stagingPath.map(Self.canonical)
        if let key {
            guard leases[key] == nil, !releasing.contains(key) else { return false }
            releasing.insert(key)
        }
        defer { if let key { releasing.remove(key) } }
        let changed = try await env.store.write { db in
            if onlyIfUnneeded,
               try EngineQueries.jobsNeedingStaging(db, key: resource.assetKey, type: resource.type, stagingGen: resource.stagingGen) > 0 {
                return false
            }
            return try ResourceRepository.releaseStaging(db, key: resource.assetKey, type: resource.type)
        }
        if changed || !onlyIfUnneeded, let path = resource.stagingPath { remove(URL(fileURLWithPath: path)) }
        return changed
    }

    /// Deletes a staged or partial file and its directory when it becomes empty.
    nonisolated func remove(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        if dir.standardizedFileURL != env.stagingDirectory.standardizedFileURL,
           (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: Startup

    private nonisolated func stagedFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: env.stagingDirectory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { item in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return url
        }
    }

    /// Removes files no resource row (exporting/ready) and no uploading job refers to (FR-32), and
    /// returns the resources whose staged file vanished back to `none`.
    @discardableResult
    func cleanupOrphans() async throws -> Int {
        let fm = FileManager.default
        let referenced: Set<String> = try await env.store.read { db in
            var paths = Set<String>()
            for state in [StagingState.ready, .exporting] {
                for r in try ResourceRepository.fetch(db, stagingState: state, limit: Int.max) {
                    if let p = r.stagingPath { paths.insert(Self.canonical(p)) }
                }
            }
            for job in try JobRepository.fetch(db, state: .uploading) {
                if let gen = job.uploadingGen {
                    paths.insert(Self.canonical(self.fileURL(of: job, generation: gen).path))
                }
            }
            return paths
        }
        var removed = 0
        for url in stagedFiles() where !referenced.contains(Self.canonical(url.path)) {
            remove(url)
            removed += 1
        }
        // A ready row whose file is gone must be exported again.
        let ready = try await env.store.read { db in try ResourceRepository.fetch(db, stagingState: .ready, limit: Int.max) }
        for resource in ready where resource.stagingPath.map({ !fm.fileExists(atPath: $0) }) ?? true {
            try await env.store.write { db in _ = try ResourceRepository.releaseStaging(db, key: resource.assetKey, type: resource.type) }
        }
        return removed
    }
}
