import Foundation
import PhotoVaultCore
import PhotoVaultDrive
@testable import PhotoVaultDropbox

struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data

    var form: [String: String] {
        var result: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            if kv.count == 2 { result[kv[0]] = kv[1] }
        }
        return result
    }

    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
}

struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ object: [String: Any]) -> StubResponse { json(200, object) }

    static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

/// Closure-driven transport that records every request. No network.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedRequest] = []
    private let handler: @Sendable (RecordedRequest) throws -> StubResponse

    init(_ handler: @escaping @Sendable (RecordedRequest) throws -> StubResponse) { self.handler = handler }

    var requests: [RecordedRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let entry = RecordedRequest(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: try body.load())
        lock.withLock { recorded.append(entry) }
        let response = try handler(entry)
        return (response.body, HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!)
    }
}

/// Download seam: answers from a closure, delivering the body in two chunks.
final class StubStreamer: DropboxByteStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedRequest] = []
    private let handler: @Sendable (RecordedRequest) throws -> StubResponse

    init(_ handler: @escaping @Sendable (RecordedRequest) throws -> StubResponse) { self.handler = handler }

    var requests: [RecordedRequest] { lock.withLock { recorded } }

    func stream(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> DropboxStreamHead {
        lock.withLock {
            recorded.append(RecordedRequest(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: Data()))
        }
        let response = try handler(recorded.last!)
        guard (200..<300).contains(response.status) else {
            return DropboxStreamHead(status: response.status, retryAfter: response.headers["Retry-After"].flatMap(TimeInterval.init), errorBody: response.body)
        }
        let half = response.body.count / 2
        try sink(response.body.prefix(half))
        try sink(response.body.dropFirst(half))
        return DropboxStreamHead(status: response.status)
    }
}

/// Token provider that counts how often a refresh was demanded.
final class StubTokens: DropboxAccessTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var refreshes = 0
    private var calls = 0
    var failRefreshWith: SourceError?

    var refreshCount: Int { lock.withLock { refreshes } }

    func accessToken(forceRefresh: Bool) async throws -> String {
        try lock.withLock {
            calls += 1
            if forceRefresh {
                refreshes += 1
                if let failRefreshWith { throw failRefreshWith }
            }
            return forceRefresh ? "fresh-token" : "old-token"
        }
    }
}

final class MemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    func delete(account: String) throws { lock.withLock { items[account] = nil } }
}

struct StubMetadata: FileMetadataReading {
    func fileMetadata(of file: URL, uti: String, mediaType: MediaType) -> FileMetadata { FileMetadata(pixelWidth: 7) }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dropbox-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeClient(tokens: StubTokens = StubTokens(), transport: StubTransport = StubTransport { _ in .json([:]) },
                streamer: StubStreamer = StubStreamer { _ in StubResponse(status: 200) }) -> DropboxClient {
    DropboxClient(tokens: tokens, transport: transport, streamer: streamer, sleep: { _ in })
}
