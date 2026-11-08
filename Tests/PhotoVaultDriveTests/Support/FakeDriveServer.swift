import CryptoKit
import Foundation
@testable import PhotoVaultDrive

/// In-memory Drive v3 server implementing the REST subset the app uses, including resumable sessions.
actor FakeDriveServer: HTTPTransport {
    struct Item {
        var id: String
        var name: String
        var mime: String
        var parents: [String]
        var content: Data?
        var props: [String: String]
        var desc: String?
        var trashed = false
        var target: String?
    }

    struct Session {
        var update: String?
        var write: [String: Any]
        var total: Int64
        var received = Data()
    }

    struct PutFailure { var status: Int; var storeBytes: Bool }

    private(set) var items: [String: Item] = ["0ADrive": Item(id: "0ADrive", name: "My Drive", mime: DriveMime.folder, parents: [], props: [:])]
    private(set) var requests: [RecordedRequest] = []
    private var generated: Set<String> = []
    private var sessions: [String: Session] = [:]
    private var counter = 0
    private let sessionPrefix: String
    var putFailures: [PutFailure] = []
    var shortcutStatus: Int?
    var corruptMD5 = false

    init(sessionPrefix: String = "up") { self.sessionPrefix = sessionPrefix }

    func setPutFailures(_ failures: [PutFailure]) { putFailures = failures }
    func setShortcutStatus(_ status: Int?) { shortcutStatus = status }
    func setCorruptMD5(_ value: Bool) { corruptMD5 = value }
    func dropSessions() { sessions.removeAll() }
    func trash(_ id: String) { items[id]?.trashed = true }
    func remove(_ id: String) { items[id] = nil }
    func item(_ id: String) -> Item? { items[id] }

    // MARK: Transport

    func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let entry = RecordedRequest(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: try body.load())
        requests.append(entry)
        let response = route(entry)
        return (response.body, response.http(for: url))
    }

    private func route(_ r: RecordedRequest) -> StubResponse {
        guard r.headers["Authorization"]?.hasPrefix("Bearer ") == true else { return error(401, "authError") }
        let path = r.url.path
        let q = r.query
        switch (r.method, path) {
        case ("GET", "/drive/v3/files/generateIds"): return generateIds(q)
        case ("GET", "/drive/v3/about"): return .json(200, ["storageQuota": ["limit": "1000", "usage": "250"]])
        case ("GET", "/drive/v3/files"): return list(q)
        case ("POST", "/drive/v3/files"): return create(r.json, shortcutFail: true)
        case ("POST", "/upload/drive/v3/files"): return startSession(r, update: nil)
        case ("PUT", "/upload/drive/v3/files"): return put(r)
        default: break
        }
        if path.hasPrefix("/upload/drive/v3/files/"), r.method == "PATCH" {
            return startSession(r, update: String(path.dropFirst("/upload/drive/v3/files/".count)))
        }
        if path.hasPrefix("/drive/v3/files/") {
            let id = String(path.dropFirst("/drive/v3/files/".count))
            if r.method == "GET" { return items[id].map { .json(200, render($0)) } ?? error(404, "notFound") }
            if r.method == "PATCH" { return update(id, r) }
        }
        return error(400, "badRequest")
    }

    private func error(_ status: Int, _ reason: String) -> StubResponse {
        .json(status, ["error": ["code": status, "errors": [["reason": reason]]]])
    }

    private func generateIds(_ q: [String: String]) -> StubResponse {
        guard q["space"] == "drive", ["files", "shortcuts"].contains(q["type"] ?? "") else { return error(400, "badRequest") }
        let count = Int(q["count"] ?? "") ?? 0
        let ids = (0..<count).map { _ -> String in counter += 1; return "id\(counter)" }
        generated.formUnion(ids)
        return .json(200, ["ids": ids, "space": "drive"])
    }

    private func isTrashed(_ item: Item) -> Bool {
        item.trashed || item.parents.contains { items[$0].map(isTrashed) ?? false }
    }

    private func render(_ item: Item) -> [String: Any] {
        var out: [String: Any] = ["id": item.id, "name": item.name, "mimeType": item.mime, "parents": item.parents,
                                  "trashed": isTrashed(item), "appProperties": item.props]
        if let content = item.content {
            out["size"] = String(content.count)
            let md5 = Insecure.MD5.hash(data: content).map { String(format: "%02x", $0) }.joined()
            out["md5Checksum"] = corruptMD5 ? String(md5.reversed()) : md5
        }
        if let target = item.target { out["shortcutDetails"] = ["targetId": target] }
        if let desc = item.desc { out["description"] = desc }
        return out
    }

    private func make(_ write: [String: Any], content: Data?) -> StubResponse {
        guard let id = write["id"] as? String, generated.contains(id) else { return error(400, "badRequest") }
        if items[id] != nil { return error(409, "duplicate") }
        let parents = write["parents"] as? [String] ?? ["0ADrive"]
        guard parents.allSatisfy({ items[$0] != nil }) else { return error(404, "notFound") }
        let item = Item(id: id, name: write["name"] as? String ?? "", mime: write["mimeType"] as? String ?? "application/octet-stream",
                        parents: parents, content: content, props: write["appProperties"] as? [String: String] ?? [:],
                        desc: write["description"] as? String, target: (write["shortcutDetails"] as? [String: String])?["targetId"])
        items[id] = item
        return .json(200, render(item))
    }

    private func create(_ write: [String: Any], shortcutFail: Bool) -> StubResponse {
        if shortcutFail, write["mimeType"] as? String == DriveMime.shortcut, let status = shortcutStatus {
            return error(status, "insufficientPermissions")
        }
        return make(write, content: nil)
    }

    private func update(_ id: String, _ r: RecordedRequest) -> StubResponse {
        guard var item = items[id] else { return error(404, "notFound") }
        let body = r.json
        if body["mimeType"] == nil, item.mime == DriveMime.shortcut, let status = shortcutStatus { return error(status, "forbidden") }
        if let name = body["name"] as? String { item.name = name }
        if let trashed = body["trashed"] as? Bool { item.trashed = trashed }
        if let desc = body["description"] as? String { item.desc = desc }
        if let props = body["appProperties"] as? [String: String] { item.props.merge(props) { $1 } }
        let q = r.query
        for p in (q["removeParents"] ?? "").split(separator: ",") { item.parents.removeAll { $0 == p } }
        for p in (q["addParents"] ?? "").split(separator: ",") { item.parents.append(String(p)) }
        items[id] = item
        return .json(200, render(item))
    }

    // MARK: Resumable

    private func startSession(_ r: RecordedRequest, update: String?) -> StubResponse {
        guard r.query["uploadType"] == "resumable", let total = Int64(r.headers["X-Upload-Content-Length"] ?? "") else { return error(400, "badRequest") }
        let write = r.json
        if let update {
            guard items[update] != nil else { return error(404, "notFound") }
        } else {
            guard let id = write["id"] as? String, generated.contains(id) else { return error(400, "badRequest") }
            if items[id] != nil { return error(409, "duplicate") }
            let parents = write["parents"] as? [String] ?? ["0ADrive"]
            guard parents.allSatisfy({ items[$0] != nil }) else { return error(404, "notFound") }
        }
        counter += 1
        let sid = "\(sessionPrefix)-\(counter)"
        sessions[sid] = Session(update: update, write: write, total: total)
        return StubResponse(status: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=\(sid)"])
    }

    private func put(_ r: RecordedRequest) -> StubResponse {
        guard let sid = r.query["upload_id"], var session = sessions[sid] else { return error(404, "notFound") }
        let range = r.headers["Content-Range"] ?? ""
        if range.hasPrefix("bytes */") { return progress(session) }
        if !putFailures.isEmpty {
            let failure = putFailures.removeFirst()
            if failure.storeBytes { session.received.append(r.body); sessions[sid] = session }
            return error(failure.status, "backendError")
        }
        let start = range.dropFirst(6).split(separator: "-").first.flatMap { Int($0) } ?? -1
        guard start == session.received.count else { return progress(session) }
        session.received.append(r.body)
        sessions[sid] = session
        guard Int64(session.received.count) == session.total else { return progress(session) }
        sessions[sid] = nil
        if let id = session.update {
            items[id]?.content = session.received
            return .json(200, render(items[id]!))
        }
        return make(session.write, content: session.received)
    }

    private func progress(_ session: Session) -> StubResponse {
        if Int64(session.received.count) == session.total, session.total > 0 { return error(500, "backendError") }
        var headers: [String: String] = [:]
        if !session.received.isEmpty { headers["Range"] = "bytes=0-\(session.received.count - 1)" }
        return StubResponse(status: 308, headers: headers)
    }

    // MARK: Query

    private func list(_ q: [String: String]) -> StubResponse {
        guard let expression = q["q"], let predicates = QueryParser.parse(expression) else { return error(400, "invalidQuery") }
        let matches = items.values.filter { item in
            item.id != "0ADrive" && predicates.allSatisfy { $0(item, isTrashed(item)) }
        }.sorted { $0.id < $1.id }
        let size = min(Int(q["pageSize"] ?? "") ?? 100, 2)  // force paging
        let start = Int(q["pageToken"] ?? "") ?? 0
        let page = Array(matches.dropFirst(start).prefix(size))
        var out: [String: Any] = ["files": page.map(render)]
        if start + size < matches.count { out["nextPageToken"] = String(start + size) }
        return .json(200, out)
    }
}

/// Parses exactly the `q` forms `DriveQuery` can produce, with Drive's escaping rules.
enum QueryParser {
    typealias Predicate = (FakeDriveServer.Item, Bool) -> Bool
    private static let lit = #"'((?:\\.|[^'\\])*)'"#

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func parse(_ expression: String) -> [Predicate]? {
        var rest = Substring(expression)
        var predicates: [Predicate] = []
        while !rest.isEmpty {
            if rest.hasPrefix(" and ") { rest = rest.dropFirst(5) }
            if rest.hasPrefix("trashed=false") {
                predicates.append { _, trashed in !trashed }
                rest = rest.dropFirst("trashed=false".count)
            } else if let m = match(#"^appProperties has \{ key="# + lit + " and value=" + lit + #" \}"#, rest) {
                let (k, v) = (unescape(m[1]), unescape(m[2]))
                predicates.append { item, _ in item.props[k] == v }
                rest = rest.dropFirst(m[0].count)
            } else if let m = match("^" + lit + " in parents", rest) {
                let id = unescape(m[1])
                predicates.append { item, _ in item.parents.contains(id) }
                rest = rest.dropFirst(m[0].count)
            } else if let m = match("^name=" + lit, rest) {
                let name = unescape(m[1])
                predicates.append { item, _ in item.name == name }
                rest = rest.dropFirst(m[0].count)
            } else if let m = match("^mimeType=" + lit, rest) {
                let mime = unescape(m[1])
                predicates.append { item, _ in item.mime == mime }
                rest = rest.dropFirst(m[0].count)
            } else {
                return nil
            }
        }
        return predicates
    }

    private static func match(_ pattern: String, _ text: Substring) -> [String]? {
        let s = String(text)
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { String(s[Range(m.range(at: $0), in: s)!]) }
    }
}
