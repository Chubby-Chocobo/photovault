import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

/// Answers requests from a table keyed by host, so tests can run side by side.
final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data]
        /// false: the connection stays open after the chunks (until the request is cancelled).
        var finishes = true
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var stopped: Set<String> = []

    static func set(_ script: Script, host: String) { lock.withLock { scripts[host] = script; stopped.remove(host) } }
    static func wasStopped(host: String) -> Bool { lock.withLock { stopped.contains(host) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let script = Self.lock.withLock({ Self.scripts[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: script.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in script.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if script.finishes { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        if let host = request.url?.host { Self.lock.withLock { _ = Self.stopped.insert(host) } }
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var all: Data { lock.withLock { data } }
}

func scriptedTransport() -> URLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedURLProtocol.self]
    return URLSessionTransport(configuration: configuration)
}

@Suite struct URLSessionStreamerTests {
    private func request(_ host: String) -> URLRequest { URLRequest(url: URL(string: "https://\(host)/file")!) }

    @Test func deliversTheBodyInOrderAndReturnsNoErrorBody() async throws {
        let host = "ok-\(UUID().uuidString.lowercased()).test"
        ScriptedURLProtocol.set(.init(chunks: [Data("ab".utf8), Data("cd".utf8), Data("ef".utf8)]), host: host)
        let got = Received()
        let (body, response) = try await scriptedTransport().stream(request(host)) { got.add($0) }
        #expect(String(decoding: got.all, as: UTF8.self) == "abcdef" && body.isEmpty && response.statusCode == 200)
    }

    @Test func anErrorStatusKeepsTheStartOfTheBodyAndNeverCallsTheSink() async throws {
        let host = "err-\(UUID().uuidString.lowercased()).test"
        ScriptedURLProtocol.set(.init(status: 429, headers: ["Retry-After": "7"], chunks: [Data("slow down".utf8)]), host: host)
        let got = Received()
        let (body, response) = try await scriptedTransport().stream(request(host)) { got.add($0) }
        #expect(response.statusCode == 429 && response.value(forHTTPHeaderField: "Retry-After") == "7")
        #expect(String(decoding: body, as: UTF8.self) == "slow down" && got.all.isEmpty)
    }

    @Test func aThrowingSinkStopsTheTransferWithItsError() async throws {
        let host = "sink-\(UUID().uuidString.lowercased()).test"
        ScriptedURLProtocol.set(.init(chunks: [Data(count: 256 << 10)], finishes: false), host: host)
        await #expect(throws: SourceError.cancelled) {
            _ = try await scriptedTransport().stream(self.request(host)) { _ in throw SourceError.cancelled }
        }
    }

    @Test func cancellingMidBodyThrowsInsteadOfReturningAShortBody() async throws {
        let host = "cancel-\(UUID().uuidString.lowercased()).test"
        ScriptedURLProtocol.set(.init(chunks: [Data(count: 256 << 10)], finishes: false), host: host)
        let got = Received()
        let transport = scriptedTransport()
        let task = Task { try await transport.stream(self.request(host)) { got.add($0) } }
        for _ in 0..<200 where got.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!got.all.isEmpty)
        task.cancel()
        let outcome = await task.result
        switch outcome {
        case .success: Issue.record("a cancelled download must not report success")
        case .failure(let error): #expect(error is CancellationError, "\(error)")
        }
        for _ in 0..<200 where !ScriptedURLProtocol.wasStopped(host: host) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ScriptedURLProtocol.wasStopped(host: host), "the network request was cancelled too")
    }

    @Test func aFailedRequestThrowsTheTransportError() async throws {
        let transport = scriptedTransport()
        await #expect(throws: URLError.self) {
            _ = try await transport.stream(self.request("unscripted-\(UUID().uuidString.lowercased()).test")) { _ in }
        }
    }
}
