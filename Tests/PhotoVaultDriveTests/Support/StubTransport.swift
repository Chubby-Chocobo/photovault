import Foundation
@testable import PhotoVaultDrive

struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data

    var query: [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }

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

    static func json(_ status: Int = 200, _ object: [String: Any], headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    func http(for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

/// Closure-driven transport that records every request. No network.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedRequest] = []
    private let handler: @Sendable (RecordedRequest) throws -> StubResponse

    init(_ handler: @escaping @Sendable (RecordedRequest) throws -> StubResponse) { self.handler = handler }

    var requests: [RecordedRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let entry = RecordedRequest(method: request.httpMethod ?? "GET", url: url,
                                    headers: request.allHTTPHeaderFields ?? [:], body: try body.load())
        lock.withLock { recorded.append(entry) }
        let response = try handler(entry)
        return (response.body, response.http(for: url))
    }
}

/// Sends OAuth hosts to one transport and everything else to another.
struct RouterTransport: HTTPTransport {
    let oauth: any HTTPTransport
    let drive: any HTTPTransport

    func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? ""
        let isOAuth = host == "oauth2.googleapis.com" || host == "accounts.google.com"
        return try await (isOAuth ? oauth : drive).send(request, body: body)
    }
}
