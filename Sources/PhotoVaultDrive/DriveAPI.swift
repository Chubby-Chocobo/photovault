import Foundation
import PhotoVaultCore

/// Drive v3 REST endpoints used by the app. Throws `DestinationError` only.
public struct DriveAPI: Sendable {
    static let fileFields = "id,name,md5Checksum,trashed,parents,size,appProperties,shortcutDetails,mimeType"
    static let maxIdsPerRequest = 1000

    let http: DriveHTTP
    let writeLimiter: DriveWriteLimiter?

    public init(transport: any HTTPTransport, auth: any DriveAuthorizing, writeLimiter: DriveWriteLimiter? = nil) {
        http = DriveHTTP(transport: transport, auth: auth)
        self.writeLimiter = writeLimiter
    }

    private func fileURL(_ id: String, _ extra: [(String, String)] = []) -> URL {
        DriveURL.make(DriveURL.api, "/files/" + FormEncoding.escape(id), extra + [("fields", Self.fileFields)])
    }

    /// Pre-generates IDs (`space=drive`), in batches of at most 1000.
    func generateIds(count: Int, kind: ReservedIdKind) async throws -> [String] {
        struct Response: Decodable { var ids: [String] }
        var ids: [String] = []
        while ids.count < count {
            let batch = min(Self.maxIdsPerRequest, count - ids.count)
            let url = DriveURL.make(DriveURL.api, "/files/generateIds",
                                    [("count", String(batch)), ("space", "drive"), ("type", kind.rawValue)])
            let response = try await http.sendJSON(Response.self, url, method: "GET")
            guard !response.ids.isEmpty else { throw DestinationError.itemRejected(reason: "generateIds returned nothing") }
            ids += response.ids
        }
        return Array(ids.prefix(count))
    }

    /// Creates metadata-only items (folders, shortcuts). 409 becomes `alreadyExists`; never assume success.
    func create(_ write: DriveFileWrite) async throws -> DriveFile {
        try await writeLimiter?.acquire(lane: .metadata)
        do {
            return try await http.sendJSON(DriveFile.self, DriveURL.make(DriveURL.api, "/files", [("fields", Self.fileFields)]),
                                           method: "POST", payload: write)
        } catch DestinationError.alreadyExists {
            throw DestinationError.alreadyExists(remoteId: write.id ?? "")
        }
    }

    func get(_ id: String) async throws -> DriveFile {
        try await http.sendJSON(DriveFile.self, fileURL(id), method: "GET")
    }

    func update(_ id: String, _ write: DriveFileWrite, addParents: [String] = [], removeParents: [String] = []) async throws -> DriveFile {
        try await writeLimiter?.acquire(lane: .metadata)
        var extra: [(String, String)] = []
        if !addParents.isEmpty { extra.append(("addParents", addParents.joined(separator: ","))) }
        if !removeParents.isEmpty { extra.append(("removeParents", removeParents.joined(separator: ","))) }
        return try await http.sendJSON(DriveFile.self, fileURL(id, extra), method: "PATCH", payload: write)
    }

    func listPage(_ query: DriveQuery, pageToken: String?) async throws -> DriveFilePage {
        struct Response: Decodable { var files: [DriveFile]?; var nextPageToken: String? }
        var items: [(String, String)] = [
            ("q", query.q), ("spaces", "drive"), ("pageSize", "1000"),
            ("fields", "nextPageToken,files(\(Self.fileFields))"),
        ]
        if let pageToken { items.append(("pageToken", pageToken)) }
        let response = try await http.sendJSON(Response.self, DriveURL.make(DriveURL.api, "/files", items), method: "GET")
        return DriveFilePage(files: response.files ?? [], nextPageToken: response.nextPageToken)
    }

    func quota() async throws -> Quota {
        struct Response: Decodable {
            struct Storage: Decodable { var limit: String?; var usage: String? }
            var storageQuota: Storage?
        }
        let url = DriveURL.make(DriveURL.api, "/about", [("fields", "storageQuota")])
        let storage = try await http.sendJSON(Response.self, url, method: "GET").storageQuota
        let total = storage?.limit.flatMap { Int64($0) }
        let used = storage?.usage.flatMap { Int64($0) }
        return Quota(totalBytes: total, usedBytes: used, availableBytes: total.flatMap { t in used.map { max(0, t - $0) } })
    }
}
