import Foundation

struct DropboxListEntry: Decodable, Sendable {
    var tag: String
    var name: String
    var pathDisplay: String?
    var pathLower: String?
    var size: Int64?
    var isDownloadable: Bool?
    var clientModified: String?
    var serverModified: String?

    enum CodingKeys: String, CodingKey {
        case tag = ".tag", name
        case pathDisplay = "path_display", pathLower = "path_lower", size
        case isDownloadable = "is_downloadable", clientModified = "client_modified", serverModified = "server_modified"
    }
}

struct DropboxListPage: Decodable, Sendable {
    var entries: [DropboxListEntry]
    var cursor: String
    var hasMore: Bool

    enum CodingKeys: String, CodingKey { case entries, cursor, hasMore = "has_more" }
}

/// A subfolder shown in the in-app browser. `path` is what Dropbox displays ("/Photos/2024").
public struct DropboxFolder: Hashable, Sendable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

enum DropboxDates {
    /// Dropbox timestamps are UTC without fractions ("2015-05-12T15:50:38Z").
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
