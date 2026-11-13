import CryptoKit
import Foundation
import PhotoVaultDrive

/// A Drive v3 stand-in for the memory benchmark: it answers the calls a backup makes and hashes uploaded
/// bytes as they arrive instead of keeping them, so the benchmark measures the app, not the fake.
final class BenchmarkDriveServer: @unchecked Sendable {
    private struct Item { var name: String; var mime: String; var parents: [String]; var md5: String?; var size: Int64 }
    private struct Session { var write: [String: Any]; var total: Int64; var received: Int64 = 0; var md5 = Insecure.MD5() }

    private let lock = NSLock()
    private var items: [String: Item] = ["root": Item(name: "PhotoVault", mime: "application/vnd.google-apps.folder", parents: [], size: 0)]
    private var sessions: [String: Session] = [:]
    private var counter = 0

    /// Uploaded files (not folders).
    var fileCount: Int { lock.withLock { items.values.filter { $0.md5 != nil }.count } }

    /// Answers one request. `body` is called with each piece of the request body, in order.
    func handle(method: String, url: URL, headers: [String: String], body: ((Data) -> Void) -> Void) -> (Int, [String: String], Data) {
        return lock.withLock {
            let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                                   uniquingKeysWith: { $1 })
            let path = url.path
            switch (method, path) {
            case ("GET", "/drive/v3/files/generateIds"):
                let count = Int(query["count"] ?? "") ?? 0
                let ids = (0..<count).map { _ -> String in counter += 1; return "id\(counter)" }
                return Self.json(200, ["ids": ids])
            case ("GET", "/drive/v3/about"):
                return Self.json(200, ["storageQuota": ["limit": String(Int64(1) << 50), "usage": "0"]])
            case ("GET", "/drive/v3/files"):
                return Self.json(200, ["files": [Any]()])
            case ("POST", "/drive/v3/files"):
                let write = Self.collectJSON(body)
                guard let id = write["id"] as? String else { return Self.json(400, ["error": ["code": 400]]) }
                if items[id] != nil { return Self.json(409, ["error": ["code": 409]]) }
                items[id] = Item(name: write["name"] as? String ?? "", mime: write["mimeType"] as? String ?? "", parents: write["parents"] as? [String] ?? [], size: 0)
                return Self.json(200, render(id))
            case ("POST", "/upload/drive/v3/files"):
                let write = Self.collectJSON(body)
                counter += 1
                let sid = "s\(counter)"
                sessions[sid] = Session(write: write, total: Int64(headers["X-Upload-Content-Length"] ?? "") ?? 0)
                return (200, ["Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=\(sid)"], Data())
            case ("PUT", "/upload/drive/v3/files"):
                guard let sid = query["upload_id"], var session = sessions[sid] else { return Self.json(404, ["error": ["code": 404]]) }
                body { chunk in
                    session.md5.update(data: chunk)
                    session.received += Int64(chunk.count)
                }
                guard session.received >= session.total else {
                    sessions[sid] = session
                    return (308, ["Range": "bytes=0-\(session.received - 1)"], Data())
                }
                sessions[sid] = nil
                let id = session.write["id"] as? String ?? "?"
                let md5 = session.md5.finalize().map { String(format: "%02x", $0) }.joined()
                items[id] = Item(name: session.write["name"] as? String ?? "", mime: "application/octet-stream",
                                 parents: session.write["parents"] as? [String] ?? [], md5: md5, size: session.total)
                return Self.json(200, render(id))
            default:
                if method == "GET", path.hasPrefix("/drive/v3/files/") {
                    let id = String(path.dropFirst("/drive/v3/files/".count))
                    return items[id] == nil ? Self.json(404, ["error": ["code": 404]]) : Self.json(200, render(id))
                }
                return Self.json(400, ["error": ["code": 400]])
            }
        }
    }

    private func render(_ id: String) -> [String: Any] {
        guard let item = items[id] else { return [:] }
        var out: [String: Any] = ["id": id, "name": item.name, "mimeType": item.mime, "parents": item.parents, "trashed": false]
        if let md5 = item.md5 { out["md5Checksum"] = md5; out["size"] = String(item.size) }
        return out
    }

    private static func collectJSON(_ body: ((Data) -> Void) -> Void) -> [String: Any] {
        var data = Data()
        body { data.append($0) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func json(_ status: Int, _ object: Any) -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

/// Routes a real `URLSession` to the benchmark server, so the upload goes through the same transport as in the app.
final class BenchmarkDriveProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: BenchmarkDriveServer?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("googleapis.com") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let request = request
        let (status, headers, data) = server.handle(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:]) { sink in
            if let body = request.httpBody { sink(body); return }
            guard let stream = request.httpBodyStream else { return }
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                sink(Data(buffer[0..<read]))
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The app's transport over a session whose requests this protocol answers.
    static func transport(_ server: BenchmarkDriveServer) -> URLSessionTransport {
        Self.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BenchmarkDriveProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSessionTransport(configuration: configuration)
    }
}

struct BenchmarkDriveAuth: DriveAuthorizing {
    func accessToken() async throws -> String { "token" }
    func refreshAfterUnauthorized(rejected: String) async throws -> String { "token" }
}
