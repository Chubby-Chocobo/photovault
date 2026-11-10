import Foundation
import PhotoVaultCore
import UniformTypeIdentifiers

/// A Drive item as the import reads it.
struct ImportItem: Decodable, Sendable {
    var id: String
    var name: String?
    var mimeType: String?
    var size: String?
    var trashed: Bool?
    var appProperties: [String: String]?
    var createdTime: String?
    var modifiedTime: String?

    static let fields = "id,name,mimeType,size,trashed,appProperties,createdTime,modifiedTime"

    var isFolder: Bool { mimeType == DriveMime.folder }

    /// Google Docs, shortcuts, trashed items and anything PhotoVault itself wrote are not photos to import.
    var isSkipped: Bool {
        if trashed == true { return true }
        if let mimeType, mimeType.hasPrefix("application/vnd.google-apps."), !isFolder { return true }
        return appProperties?.keys.contains { $0.hasPrefix("pv") } == true
    }
}

enum ImportNames {
    /// A name that is safe as one path component.
    static func sanitize(_ raw: String?) -> String {
        var name = (raw ?? "").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "_" + name }
        return name.precomposedStringWithCanonicalMapping
    }

    /// Names for one directory: sorted by id, the first keeps its name and later duplicates (case-insensitive,
    /// as on the Mac) become `stem (2).ext`, `stem (3).ext`.
    static func assign(_ items: [ImportItem]) -> [(item: ImportItem, name: String)] {
        var used = Set<String>()
        var result: [(ImportItem, String)] = []
        for item in items.sorted(by: { $0.id < $1.id }) {
            let base = sanitize(item.name)
            var candidate = base
            var n = 2
            while !used.insert(candidate.lowercased()).inserted {
                let ext = (base as NSString).pathExtension
                let stem = ext.isEmpty ? base : String(base.dropLast(ext.count + 1))
                candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
                n += 1
            }
            result.append((item, candidate))
        }
        return result
    }

    /// UTI for photos, videos and the sidecars the importer counts; nil for anything else.
    static func uti(name: String, mimeType: String?) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? mimeType.flatMap { UTType(mimeType: $0) }
            ?? (FolderItemGrouper.ignoredExtensions.contains(ext) ? UTType.data : nil)
        guard let type else { return nil }
        if type.conforms(to: .image) || type.conforms(to: .movie) { return type.identifier }
        return FolderItemGrouper.ignoredExtensions.contains(ext) ? type.identifier : nil
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Walks the picked items and records which file each relative path names.
struct DriveImportLister: Sendable {
    static let maxDepth = 64
    /// Picked items read at the same time, and tries per item.
    static let pickedParallelism = 8
    static let itemAttempts = 3

    let http: DriveHTTP
    let pickedIds: [String]

    struct Listing: Sendable {
        var entries: [FolderFileEntry] = []
        var ids: [String: String] = [:]

        /// A file picked on its own and also found inside a picked folder is read once, under the deeper path
        /// (the one that keeps its folder); a tie goes to the path that sorts first.
        mutating func dropRepeatedFiles() {
            var best: [String: String] = [:]
            for (path, id) in ids {
                guard let kept = best[id] else { best[id] = path; continue }
                let depth = path.split(separator: "/").count, keptDepth = kept.split(separator: "/").count
                if depth > keptDepth || (depth == keptDepth && path.utf8.lexicographicallyPrecedes(kept.utf8)) { best[id] = path }
            }
            let keep = Set(best.values)
            ids = ids.filter { keep.contains($0.key) }
            entries = entries.filter { keep.contains($0.relativePath) }
        }
    }

    func list() async throws -> Listing {
        let roots = try await pickedItems()
        var listing = Listing()
        var visited = Set<String>()
        try await walk(roots.filter { !$0.isSkipped }, prefix: "", depth: 0, visited: &visited, into: &listing)
        listing.dropRepeatedFiles()
        listing.entries.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        return listing
    }

    /// Picked items read side by side, a few at a time. The result keeps the order of `pickedIds`, so it does not
    /// depend on which answer comes first. An item Drive refuses to show is left out.
    private func pickedItems() async throws -> [ImportItem] {
        try await withThrowingTaskGroup(of: (Int, ImportItem?).self) { group in
            var found: [(Int, ImportItem)] = []
            var next = 0
            func startNext() {
                guard next < pickedIds.count else { return }
                let index = next, id = pickedIds[next]
                next += 1
                group.addTask { (index, try await self.itemWithRetry(id)) }
            }
            for _ in 0..<min(Self.pickedParallelism, pickedIds.count) { startNext() }
            while let (index, item) = try await group.next() {
                if let item { found.append((index, item)) }
                startNext()
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// One picked item. A hiccup (server error, throttling, dropped connection) is retried for this item alone;
    /// when it persists the error goes up and the listing is busy.
    private func itemWithRetry(_ id: String) async throws -> ImportItem? {
        var attempt = 1
        while true {
            do { return try await item(id) } catch where Self.isPerItem(error) { return nil } catch {
                guard attempt < Self.itemAttempts, Self.isHiccup(error) else { throw error }
                try await Task.sleep(for: .milliseconds(200 * attempt))
                attempt += 1
            }
        }
    }

    private static func isHiccup(_ error: any Error) -> Bool {
        switch error as? DestinationError {
        case .rateLimited, .server, .transient: true
        default: false
        }
    }

    /// A missing item or one the app may not read (403) says nothing about the source: Drive answered, this item is skipped.
    static func isPerItem(_ error: any Error) -> Bool {
        guard let error = error as? DestinationError else { return false }
        switch error {
        case .notFound: return true
        case .itemRejected(let reason): return reason.hasPrefix("http 403")
        default: return false
        }
    }

    func item(_ id: String) async throws -> ImportItem {
        let url = DriveURL.make(DriveURL.api, "/files/" + FormEncoding.escape(id), [("fields", ImportItem.fields), ("supportsAllDrives", "true")])
        return try await http.sendJSON(ImportItem.self, url, method: "GET")
    }

    private func walk(_ items: [ImportItem], prefix: String, depth: Int, visited: inout Set<String>, into listing: inout Listing) async throws {
        for (item, name) in ImportNames.assign(items) {
            let path = prefix + name
            if item.isFolder {
                guard depth < Self.maxDepth, visited.insert(item.id).inserted else { continue }
                let children: [ImportItem]
                do { children = try await self.children(of: item.id).filter { !$0.isSkipped } } catch where Self.isPerItem(error) { continue }
                try await walk(children, prefix: path + "/", depth: depth + 1, visited: &visited, into: &listing)
            } else if let uti = ImportNames.uti(name: name, mimeType: item.mimeType) {
                listing.ids[path] = item.id
                listing.entries.append(FolderFileEntry(
                    relativePath: path, uti: uti, sizeBytes: item.size.flatMap { Int64($0) } ?? 0,
                    creationDate: ImportNames.date(item.createdTime), modificationDate: ImportNames.date(item.modifiedTime)))
            }
        }
    }

    /// A folder with nothing the app may read is an empty list, not an error.
    private func children(of folderId: String) async throws -> [ImportItem] {
        struct Page: Decodable { var files: [ImportItem]?; var nextPageToken: String? }
        var all: [ImportItem] = []
        var token: String?
        repeat {
            var query: [(String, String)] = [
                ("q", DriveQuery.all.parent(folderId).notTrashed.q), ("spaces", "drive"), ("pageSize", "1000"),
                ("fields", "nextPageToken,files(\(ImportItem.fields))"),
                ("supportsAllDrives", "true"), ("includeItemsFromAllDrives", "true"),
            ]
            if let token { query.append(("pageToken", token)) }
            let page = try await http.sendJSON(Page.self, DriveURL.make(DriveURL.api, "/files", query), method: "GET")
            all += page.files ?? []
            token = page.nextPageToken
        } while token != nil
        return all
    }
}
