import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

private struct ChunkedTransport: StreamingTransport {
    let status: Int
    func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse) { fatalError("buffered path must not be used") }
    func stream(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        guard status == 200 else { return (Data("{}".utf8), response) }
        for part in ["ab", "cd", "ef"] { try sink(Data(part.utf8)) }
        return (Data(), response)
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []
    func add(_ data: Data) { lock.withLock { chunks.append(String(decoding: data, as: UTF8.self)) } }
    var all: [String] { lock.withLock { chunks } }
}

@Suite struct StreamingDownloadTests {
    private let url = URL(string: "https://www.googleapis.com/drive/v3/files/x?alt=media")!

    @Test func streamingTransportDeliversChunksInOrder() async throws {
        let http = DriveHTTP(transport: ChunkedTransport(status: 200), auth: FixedTokenAuth(token: "t"))
        let got = Collector()
        try await http.download(url) { got.add($0) }
        #expect(got.all == ["ab", "cd", "ef"])
    }

    @Test func errorStatusNeverReachesTheSink() async throws {
        let http = DriveHTTP(transport: ChunkedTransport(status: 404), auth: FixedTokenAuth(token: "t"))
        let got = Collector()
        await #expect(throws: DestinationError.notFound) { try await http.download(url) { got.add($0) } }
        #expect(got.all.isEmpty)
    }

    @Test func loggingWrapperForwardsStreaming() async throws {
        let http = DriveHTTP(transport: LoggingHTTPTransport(wrapping: ChunkedTransport(status: 200), log: NullLogSink()),
                             auth: FixedTokenAuth(token: "t"))
        let got = Collector()
        try await http.download(url) { got.add($0) }
        #expect(got.all.count == 3)
    }

    @Test func sinkErrorStopsTheTransfer() async throws {
        let http = DriveHTTP(transport: ChunkedTransport(status: 200), auth: FixedTokenAuth(token: "t"))
        await #expect(throws: SourceError.cancelled) { try await http.download(url) { _ in throw SourceError.cancelled } }
    }
}
