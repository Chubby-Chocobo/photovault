import Foundation
import PhotoVaultCore
@testable import PhotoVaultDrive

/// A tiny Drive v3 read API: file metadata, folder listing with paging, and `alt=media` content.
final class ImportDriveStub: HTTPTransport, @unchecked Sendable {
    struct Node {
        var id: String
        var name: String
        var mime: String = "image/jpeg"
        var parent: String?
        var content: Data = Data()
        var trashed = false
        var props: [String: String] = [:]
        /// Picked folders may hide their children from the app.
        var hidesChildren = false
        /// The "My Drive" folder, also answered for the `root` alias.
        var isRoot = false
        var driveId: String?
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var order: [String] = []
    private var recorded: [URLRequest] = []
    private var failures: [String: StubResponse] = [:]
    private var listingFailures: [String: StubResponse] = [:]
    private var oneShots: [String: StubResponse] = [:]
    private var inFlight = 0
    private var peak = 0
    var pageSize = 1000
    /// Each answer takes this long, so overlapping requests can be seen.
    var latency: Duration = .zero
    let validToken = LockedBox("token-1")

    func add(_ node: Node) { lock.withLock { nodes[node.id] = node; order.append(node.id) } }
    func remove(_ id: String) { lock.withLock { nodes[id] = nil } }
    func fail(_ id: String, with response: StubResponse) { lock.withLock { failures[id] = response } }
    /// The next request for this id answers `response`, then it answers normally.
    func failOnce(_ id: String, with response: StubResponse) { lock.withLock { oneShots[id] = response } }
    /// The most requests that were waiting for an answer at the same time.
    var peakInFlight: Int { lock.withLock { peak } }
    /// Metadata requests for one id (not listings or downloads).
    func metadataRequests(for id: String) -> Int {
        requests.filter { $0.url?.path == "/drive/v3/files/" + id && !($0.url?.query ?? "").contains("alt=media") }.count
    }
    /// Listing the children of this folder answers `response`.
    func failListing(of id: String, with response: StubResponse) { lock.withLock { listingFailures[id] = response } }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var listingRequests: Int { requests.filter { $0.url?.path == "/drive/v3/files" }.count }

    func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            recorded.append(request)
            inFlight += 1
            peak = max(peak, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if latency > .zero { try await Task.sleep(for: latency) }
        let url = request.url!
        let response = route(request, url)
        return (response.body, response.http(for: url))
    }

    private func route(_ request: URLRequest, _ url: URL) -> StubResponse {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer " + validToken.value else {
            return .json(401, ["error": ["errors": [["reason": "authError"]]]])
        }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        return lock.withLock {
            if url.path == "/drive/v3/files" { return list(query) }
            let id = String(url.path.dropFirst("/drive/v3/files/".count))
            if id == "root", let root = nodes.values.first(where: \.isRoot) { return .json(200, render(root)) }
            if let failure = failures[id] { return failure }
            if let once = oneShots.removeValue(forKey: id) { return once }
            guard let node = nodes[id] else { return .json(404, ["error": ["errors": [["reason": "notFound"]]]]) }
            if query["alt"] == "media" { return StubResponse(status: 200, body: node.content) }
            return .json(200, render(node))
        }
    }

    private func list(_ query: [String: String]) -> StubResponse {
        let q = query["q"] ?? ""
        guard let open = q.firstIndex(of: "'"), let close = q[q.index(after: open)...].firstIndex(of: "'") else { return .json(400, [:]) }
        let parentId = String(q[q.index(after: open)..<close])
        if let failure = listingFailures[parentId] { return failure }
        if nodes[parentId]?.hidesChildren == true { return .json(200, ["files": []]) }
        let all = order.compactMap { nodes[$0] }.filter { $0.parent == parentId && !$0.trashed }
        let start = Int(query["pageToken"] ?? "0") ?? 0
        let page = Array(all.dropFirst(start).prefix(pageSize))
        var body: [String: Any] = ["files": page.map(render)]
        if start + pageSize < all.count { body["nextPageToken"] = String(start + pageSize) }
        return .json(200, body)
    }

    private func render(_ node: Node) -> [String: Any] {
        var json: [String: Any] = ["id": node.id, "name": node.name, "mimeType": node.mime, "trashed": node.trashed,
                                   "createdTime": "2024-05-01T10:00:00.000Z", "modifiedTime": "2024-05-02T10:00:00Z"]
        if node.mime != DriveMime.folder { json["size"] = String(node.content.count) }
        if let parent = node.parent { json["parents"] = [parent] }
        if let driveId = node.driveId { json["driveId"] = driveId }
        if !node.props.isEmpty { json["appProperties"] = node.props }
        return json
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

struct StubMetadataReader: FileMetadataReading {
    func fileMetadata(of file: URL, uti: String, mediaType: MediaType) -> FileMetadata {
        FileMetadata(pixelWidth: (try? Data(contentsOf: file).count) ?? -1)
    }
}
