import Foundation
import PhotoVaultCore

/// Which remote file each relative path of a cloud import names, kept in a small JSON file so the answer
/// does not change after a relaunch or when the provider's folder changes. A path is never given a second
/// id and an id never a second path; later listings only add what is new.
public actor RemoteIdIndex {
    private struct Stored: Codable {
        var ids: [String: String]
    }

    private var ids: [String: String]
    private var pathById: [String: String]
    private let file: URL
    private var relisting: Task<Void, any Error>?
    /// True while the map in memory is ahead of the file (a write failed); the next merge writes it again.
    private var unsaved = false
    private var lastRelist: ContinuousClock.Instant?
    private let relistInterval: Duration

    /// - Parameters:
    ///   - file: where the map is kept. A missing or unreadable file starts an empty map, which a listing then rebuilds.
    ///   - relistInterval: a path still unknown this soon after a relist is missing, not a reason to list again.
    public init(file: URL, relistInterval: Duration = .seconds(30)) {
        self.file = file
        self.relistInterval = relistInterval
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        ids = stored?.ids ?? [:]
        pathById = Dictionary(ids.map { ($0.value, $0.key) }) { first, _ in first }
    }

    public func lookup(_ path: String) -> String? { ids[path] }

    /// Adds what a listing shows that is new and writes the map to disk before returning. Files the map
    /// already knows keep their path whatever name the listing now gives them; a new file whose path is taken
    /// is not part of this import and is dropped.
    /// - Parameters:
    ///   - entries: the listing, each under the path the listing gave it.
    ///   - paths: the remote id of each listed path.
    /// - Returns: the entries under their stable paths, sorted by path.
    public func stabilize(_ entries: [FolderFileEntry], paths: [String: String]) throws -> [FolderFileEntry] {
        let stable = try merge(paths)
        return entries.compactMap { entry -> FolderFileEntry? in
            guard let id = paths[entry.relativePath], let path = stable[id] else { return nil }
            var kept = entry
            kept.relativePath = path
            return kept
        }.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    /// - Returns: the stable path of every listed id the map holds after the merge.
    @discardableResult
    public func merge(_ listing: [String: String]) throws -> [String: String] {
        var stable: [String: String] = [:]
        var changed = false
        for (path, id) in listing.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
            if let known = pathById[id] {
                stable[id] = known
            } else if ids[path] == nil {
                ids[path] = id
                pathById[id] = path
                stable[id] = path
                changed = true
            }
        }
        if changed { unsaved = true }
        if unsaved {
            try persist()
            unsaved = false
        }
        return stable
    }

    /// Id of `path`. A path that is not known runs `relist` once, however many callers ask at the same time,
    /// and merges the result.
    public func resolve(_ path: String, relist: @escaping @Sendable () async throws -> [String: String]) async throws -> String? {
        if let id = ids[path] { return id }
        if relisting == nil, let last = lastRelist, ContinuousClock.now - last < relistInterval { return nil }
        let task = relisting ?? startRelist(relist)
        try await task.value
        return ids[path]
    }

    private func startRelist(_ relist: @escaping @Sendable () async throws -> [String: String]) -> Task<Void, any Error> {
        let task = Task { try await self.runRelist(relist) }
        relisting = task
        return task
    }

    private func runRelist(_ relist: @Sendable () async throws -> [String: String]) async throws {
        defer { relisting = nil }
        try merge(try await relist())
        // Only a relist that worked makes a path that is still unknown "missing" for a while.
        lastRelist = .now
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(ids: ids))
        try data.write(to: file, options: .atomic)
    }
}
