import Foundation
import PhotoVaultCore

/// Where a Drive import came from, for the owner to read. Names stay on this Mac; never logged.
public struct DriveImportLocations: Sendable, Equatable {
    /// One path per resolved pick ("My Drive/Trips/2024"), in the order picked.
    public var paths: [String]
    /// Link to the first pick's folder (a picked file's parent folder); nil when there is none.
    public var webURL: String?
}

/// A Drive item as the location walk reads it.
struct DriveLocationNode: Decodable, Equatable, Sendable {
    var id: String
    var name: String?
    var mimeType: String?
    var parents: [String]?
    var driveId: String?

    static let fields = "id,name,mimeType,parents,driveId"
    var isFolder: Bool { mimeType == DriveMime.folder }
}

/// Builds the path of picked items by walking `parents` upwards, with one lookup per distinct item. It is
/// best-effort: any failure (network, permission, a missing item, the request budget) returns nil and the import
/// keeps its plain name.
struct DriveLocationResolver {
    static let myDrive = "My Drive"
    static let sharedWithMe = "Shared with me"

    private struct Failure: Error {}

    let lookup: @Sendable (String) async throws -> DriveLocationNode
    var maxDepth = 20
    var maxPicks = 5
    var maxLookups = 100
    private var cache: [String: DriveLocationNode] = [:]
    private var lookups = 0
    private var rootId: String?

    init(lookup: @escaping @Sendable (String) async throws -> DriveLocationNode, maxDepth: Int = 20, maxPicks: Int = 5, maxLookups: Int = 100) {
        self.lookup = lookup
        self.maxDepth = maxDepth
        self.maxPicks = maxPicks
        self.maxLookups = maxLookups
    }

    mutating func resolve(picked: [String]) async -> DriveImportLocations? {
        guard !picked.isEmpty else { return nil }
        do {
            var paths: [String] = []
            var firstFolderId: String?
            for (index, id) in picked.prefix(maxPicks).enumerated() {
                let node = try await node(id)
                let folderId = node.isFolder ? node.id : node.parents?.first
                if index == 0 { firstFolderId = folderId }
                if node.isFolder {
                    paths.append(try await chain(startingAt: node))
                } else if let parent = node.parents?.first {
                    paths.append(try await chain(startingAt: try await self.node(parent)))
                } else {
                    paths.append(Self.sharedWithMe)
                }
            }
            return DriveImportLocations(paths: paths, webURL: firstFolderId.flatMap { ImportLocationPath.driveFolderURL(id: $0)?.absoluteString })
        } catch {
            return nil
        }
    }

    /// "My Drive/A/B" for a folder; "Shared with me/…" when the chain ends outside My Drive and shared drives;
    /// a leading "…" when it is longer than `maxDepth`.
    private mutating func chain(startingAt start: DriveLocationNode) async throws -> String {
        var names: [String] = []
        var visited: Set<String> = []
        var current = start
        var terminal: DriveLocationNode?
        var cut = false
        while true {
            guard visited.insert(current.id).inserted else { cut = true; break }
            guard let name = current.name, !name.isEmpty else { throw Failure() }
            names.append(name)
            guard let parent = current.parents?.first else { terminal = current; break }
            if names.count >= maxDepth { cut = true; break }
            current = try await node(parent)
        }
        names.reverse()
        if cut { names.insert("…", at: 0) }
        else if let terminal, terminal.driveId == nil, try await root() != terminal.id { names.insert(Self.sharedWithMe, at: 0) }
        return names.joined(separator: "/")
    }

    private mutating func root() async throws -> String {
        if let rootId { return rootId }
        let id = try await node("root").id
        rootId = id
        return id
    }

    private mutating func node(_ id: String) async throws -> DriveLocationNode {
        if let cached = cache[id] { return cached }
        try Task.checkCancellation()
        guard lookups < maxLookups else { throw Failure() }
        lookups += 1
        let node = try await lookup(id)
        cache[id] = node
        cache[node.id] = node
        return node
    }
}

extension DriveImportSource {
    /// The paths of the first picked items, read with metadata GETs only. nil on any error or when `timeout`
    /// passes: this must never delay or fail the import, which keeps the folder's name.
    public func pickedLocations(timeout: Duration = .seconds(10)) async -> DriveImportLocations? {
        let http = http
        let picked = lister.pickedIds
        return await withTaskGroup(of: DriveImportLocations?.self) { group in
            group.addTask {
                var resolver = DriveLocationResolver(lookup: { id in
                    let url = DriveURL.make(DriveURL.api, "/files/" + FormEncoding.escape(id), [("fields", DriveLocationNode.fields), ("supportsAllDrives", "true")])
                    return try await http.sendJSON(DriveLocationNode.self, url, method: "GET")
                })
                return await resolver.resolve(picked: picked)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
