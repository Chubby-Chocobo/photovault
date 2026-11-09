import Foundation
import PhotoVaultCore

/// Head of a streamed response. For a non-2xx status `errorBody` holds the (small) error JSON.
public struct DropboxStreamHead: Sendable {
    public var status: Int
    public var retryAfter: TimeInterval?
    public var errorBody: Data

    public init(status: Int, retryAfter: TimeInterval? = nil, errorBody: Data = Data()) {
        self.status = status
        self.retryAfter = retryAfter
        self.errorBody = errorBody
    }
}

/// Network seam for downloads: file bytes must not be buffered whole in memory.
public protocol DropboxByteStreaming: Sendable {
    /// Calls `sink` with each chunk of a 2xx body, in order. A throwing `sink` stops the transfer and
    /// its error is rethrown. Throws `URLError` for transport failures.
    func stream(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> DropboxStreamHead
}

/// Streams with a delegate task: the per-byte `URLSession.bytes` iterator is too slow for large videos.
public struct URLSessionByteStreamer: DropboxByteStreaming {
    private static let maxErrorBody = 16 << 10
    private let configuration: URLSessionConfiguration

    public init(timeout: TimeInterval = 120) {
        configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
    }

    public func stream(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> DropboxStreamHead {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: StreamEvent.self)
        let session = URLSession(configuration: configuration, delegate: StreamDelegate(continuation), delegateQueue: nil)
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in task.cancel(); session.finishTasksAndInvalidate() }
        task.resume()
        var head: HTTPURLResponse?
        var errorBody = Data()
        for try await event in events {
            switch event {
            case .head(let response): head = response
            case .data(let data):
                if let head, (200..<300).contains(head.statusCode) { try sink(data) }
                else if errorBody.count < Self.maxErrorBody { errorBody.append(data) }
            }
        }
        guard let head else { throw URLError(.badServerResponse) }
        return DropboxStreamHead(status: head.statusCode, retryAfter: DropboxHTTP.retryAfter(head), errorBody: errorBody)
    }
}

private enum StreamEvent: @unchecked Sendable {
    case head(HTTPURLResponse)
    case data(Data)
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation

    init(_ continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation) { self.continuation = continuation }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { continuation.yield(.head(http)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: error)
    }
}
