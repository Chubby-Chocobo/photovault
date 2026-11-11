import PhotoVaultCore
import Foundation

/// Request body: nothing, in-memory data, or a byte range of a staged file (chunked upload).
public enum HTTPBody: Sendable, Equatable {
    case none
    case data(Data)
    case fileRange(URL, offset: Int64, length: Int)

    /// Materialises the body. Chunk sizes are bounded (8 MiB by default), so this is safe.
    public func load() throws -> Data {
        switch self {
        case .none: return Data()
        case .data(let data): return data
        case .fileRange(let url, let offset, let length):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length) ?? Data()
        }
    }
}

/// Network seam. Implementations return non-2xx responses as values; they throw only for
/// transport failures (`URLError`, cancellation).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    fileprivate let session: URLSession
    fileprivate let streamer: URLSessionStreamer

    /// The longest a request may go without data before it fails.
    public static let defaultRequestTimeout: TimeInterval = 120

    public init(timeout: TimeInterval = URLSessionTransport.defaultRequestTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.init(configuration: configuration)
    }

    /// For callers that need their own session setup, for example tests with a stub `URLProtocol`.
    public init(configuration: URLSessionConfiguration) {
        streamer = URLSessionStreamer(configuration: configuration)
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        switch body {
        case .none: (data, response) = try await session.data(for: request)
        default: (data, response) = try await session.upload(for: request, from: try body.load())
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Decorator that logs method, host, path template and status. Query strings, headers, bodies and
/// error descriptions (which can embed the URL) are never logged (NFR-06).
public struct LoggingHTTPTransport: HTTPTransport {
    fileprivate let base: any HTTPTransport
    fileprivate let log: any LogSink

    public init(wrapping base: any HTTPTransport, log: any LogSink) {
        self.base = base
        self.log = log
    }

    public func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse) {
        let line = "\(request.httpMethod ?? "GET") \(request.url?.host ?? "?")\(PathTemplate.make(request.url?.path ?? ""))"
        do {
            let result = try await base.send(request, body: body)
            log.log(.debug, category: "drive.http", "\(line) -> \(result.1.statusCode)")
            return result
        } catch {
            let code = (error as? URLError).map { String($0.code.rawValue) } ?? "other"
            log.log(.debug, category: "drive.http", "\(line) failed (\(code))")
            throw error
        }
    }
}

/// Replaces every path segment that is not a known literal with `:id`, so file IDs stay out of logs.
enum PathTemplate {
    private static let literals: Set<String> = [
        "drive", "v3", "upload", "files", "generateIds", "about", "token", "revoke", "oauth2", "v2", "auth",
    ]

    static func make(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { literals.contains(String($0)) ? String($0) : ":id" }
            .reduce(into: "") { $0 += "/" + $1 }
    }
}


/// A transport that can hand a response body over in chunks instead of one `Data`, so large
/// downloads never sit in memory.
public protocol StreamingTransport: HTTPTransport {
    /// 2xx: the body goes to `sink` in order and the returned data is empty. Any other status: the sink
    /// is never called and the returned data is the start of the body (error text, at most 64 KiB).
    /// A throwing sink stops the transfer and its error propagates.
    func stream(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    /// Streams when the transport can; otherwise buffers the response and replays it in chunks.
    public func streamBody(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        if let streaming = self as? any StreamingTransport { return try await streaming.stream(request, sink: sink) }
        let (data, response) = try await send(request, body: .none)
        guard (200..<300).contains(response.statusCode) else { return (data.prefix(1 << 16), response) }
        var offset = 0
        while offset < data.count {
            let end = min(offset + (1 << 20), data.count)
            try sink(data.subdata(in: data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: end)))
            offset = end
        }
        return (Data(), response)
    }
}

extension URLSessionTransport: StreamingTransport {
    public func stream(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        try await streamer.stream(request, sink: sink)
    }
}

extension LoggingHTTPTransport: StreamingTransport {
    public func stream(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        let line = "\(request.httpMethod ?? "GET") \(request.url?.host ?? "?")\(PathTemplate.make(request.url?.path ?? ""))"
        do {
            let result = try await base.streamBody(request, sink: sink)
            log.log(.debug, category: "drive.http", "\(line) -> \(result.1.statusCode)")
            return result
        } catch {
            let code = (error as? URLError).map { String($0.code.rawValue) } ?? "other"
            log.log(.debug, category: "drive.http", "\(line) failed (\(code))")
            throw error
        }
    }
}
