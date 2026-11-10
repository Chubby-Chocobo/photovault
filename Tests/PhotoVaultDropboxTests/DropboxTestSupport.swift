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

/// A transport whose connection never ends after the first chunk, so a download can be cancelled mid-body.
final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stoppedHosts: Set<String> = []

    static func wasStopped(host: String) -> Bool { lock.withLock { stoppedHosts.contains(host) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: 256 << 10))
    }

    override func stopLoading() {
        if let host = request.url?.host { Self.lock.withLock { _ = Self.stoppedHosts.insert(host) } }
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
    func accounts() throws -> [String] { lock.withLock { items.keys.sorted() } }
}

struct StubMetadata: FileMetadataReading {
    func fileMetadata(of file: URL, uti: String, mediaType: MediaType) -> FileMetadata { FileMetadata(pixelWidth: 7) }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dropbox-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeClient(tokens: StubTokens = StubTokens(), transport: any HTTPTransport = StubTransport { _ in .json([:]) }) -> DropboxClient {
    DropboxClient(tokens: tokens, transport: transport, sleep: { _ in })
}

/// A loopback port the system just handed out and released. A hard-coded port in the dynamic range can
/// already be held by another connection on the machine, which made these tests fail now and then.
func freeLoopbackPort() async throws -> UInt16 {
    let probe = try LoopbackRedirectServer(expectedState: "probe")
    let port = try await probe.start()
    probe.cancel()
    return port
}
