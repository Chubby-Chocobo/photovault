import PhotoVaultCore
import Foundation
import Network

/// One-shot HTTP listener bound to 127.0.0.1 that receives the OAuth redirect (RFC 8252 section 7.3).
/// It resolves with the first callback that carries the expected `state`, then stops listening; requests
/// on other paths get a 404 and a callback with the wrong `state` gets a 400, neither consumes the slot.
/// The browser connection of the accepted callback stays open until `respond(_:)` so the page can
/// say how the token exchange ended; if nobody answers within `replyTimeout` it gets the generic failure page.
/// Idle or slow connections are closed after `connectionTimeout`. It also cancels after `timeout`.
public final class LoopbackRedirectServer: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 300
    /// How long the accepted callback waits for `respond(_:)` before it gets the generic failure page. Between the code
    /// and the page a flow makes at most two requests (the token exchange, then an account lookup), so the fallback must
    /// not fire while a slow but successful sign-in is still finishing.
    public static let defaultReplyTimeout: TimeInterval = 2 * URLSessionTransport.defaultRequestTimeout + 30

    private let expectedState: String
    private let timeout: TimeInterval
    private let connectionTimeout: TimeInterval
    let replyTimeout: TimeInterval
    private let listener: NWListener
    private let queue = DispatchQueue(label: "photovault.loopback")
    private let lock = NSLock()
    private var outcome: Result<String, LoopbackError>?
    private var waiter: CheckedContinuation<String, any Error>?
    private var localHost: String?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var callbackConnection: NWConnection?
    private var acceptedCallback: LoopbackCallback?
    private var acceptedTotal = 0
    private var receivedTotal = 0
    private var listenerStopped = false

    public init(expectedState: String, timeout: TimeInterval = LoopbackRedirectServer.defaultTimeout,
                connectionTimeout: TimeInterval = 10, replyTimeout: TimeInterval = LoopbackRedirectServer.defaultReplyTimeout,
                port: UInt16 = 0) throws {
        self.expectedState = expectedState
        self.timeout = timeout
        self.connectionTimeout = connectionTimeout
        self.replyTimeout = replyTimeout
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
    }

    /// The parsed redirect that carried the expected `state`; lets flows read extra query items.
    public var receivedCallback: LoopbackCallback? { lock.withLock { acceptedCallback } }

    /// Local address of the first accepted connection; lets tests prove the loopback binding.
    public var acceptedLocalHost: String? { lock.withLock { localHost } }

    /// Starts listening and returns the bound port.
    public func start() async throws -> UInt16 {
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port?.rawValue { gate.resume(.success(port)) }
                    else { gate.resume(.failure(DestinationError.transient(reason: "loopback port unavailable"))) }
                case .failed, .cancelled:
                    if let self { self.lock.withLock { self.listenerStopped = true } }
                    gate.resume(.failure(DestinationError.transient(reason: "loopback listener failed")))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(.timeout)) }
        return ready
    }

    /// Connections currently open and not yet answered.
    var openConnectionCount: Int { lock.withLock { connections.count } }
    /// Connections accepted since the start, closed ones included.
    var acceptedConnectionCount: Int { lock.withLock { acceptedTotal } }
    /// Request bytes read from all connections since the start; lets a test send the next piece only once the
    /// server has read the last one, so the pieces arrive in separate reads.
    var receivedByteCount: Int { lock.withLock { receivedTotal } }
    /// True once the listener has stopped and takes no new connection.
    var hasStoppedListening: Bool { lock.withLock { listenerStopped } }

    /// Tells the browser how the flow ended and closes the callback connection. Only the first call sends a page.
    public func respond(_ page: CallbackPage) {
        let connection = lock.withLock { () -> NWConnection? in
            defer { callbackConnection = nil }
            return callbackConnection
        }
        if let connection { reply(connection, status: page.status, body: page.html) }
    }

    /// Waits for the callback and returns the validated authorization code.
    public func awaitCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome.mapError { $0 as any Error })
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish(.failure(.cancelled))
        }
    }

    public func cancel() { finish(.failure(.cancelled)) }

    private func finish(_ result: Result<String, LoopbackError>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let pending = waiter
        waiter = nil
        let idle = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        listener.cancel()
        idle.forEach { $0.cancel() }
        pending?.resume(with: result.mapError { $0 as any Error })
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let done = outcome != nil
        if !done {
            connections[ObjectIdentifier(connection)] = connection
            acceptedTotal += 1
        }
        lock.unlock()
        guard !done else { connection.cancel(); return }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectionTimeout) { [weak self] in
            guard let self else { return }
            if self.forget(connection) { connection.cancel() }
        }
        receive(connection, buffer: Data())
    }

    /// Removes the connection from the unanswered set; true when it was still there.
    private func forget(_ connection: NWConnection) -> Bool {
        lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) != nil }
    }

    private static let lineEnd = Data("\r\n".utf8)
    private static let stateKey = Data("state=".utf8)
    private static let callbackPrefix = Data("GET \(LoopbackRequestParser.callbackPath)".utf8)
    /// Long enough that a `\r\n` or `state=` split across two reads is still found.
    private static let scanOverlap = 8

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: LoopbackRequestParser.readChunkBytes) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            let previousCount = buffer.count
            var buffer = buffer
            if let data {
                buffer.append(data)
                self.lock.withLock { self.receivedTotal += data.count }
            }
            // Only the bytes that just arrived are searched (plus a short overlap), so a long request costs one pass
            // over its bytes instead of one full decode per chunk.
            let fresh = buffer.index(buffer.startIndex, offsetBy: max(0, previousCount - Self.scanOverlap))..<buffer.endIndex
            let hasRequestLine = buffer.range(of: Self.lineEnd, in: fresh) != nil
            let isCallback = buffer.starts(with: Self.callbackPrefix)
            if buffer.count >= LoopbackRequestParser.maxRequestBytes, isCallback {
                // A callback past the size limit that carries the expected state is the owner's selection, simply too
                // long: it gets a readable page and ends the flow now. The state may come after the ids, so a long
                // request is read on, up to a few times the limit, to find it. One without the state is a stray
                // request: refused, and the flow keeps waiting.
                // The search reaches back far enough to see a `state=` whose value finished in this read.
                let stateWindow = buffer.index(buffer.startIndex, offsetBy: max(0, previousCount - Self.stateKey.count - self.expectedState.utf8.count))..<buffer.endIndex
                let mayCarryState = buffer.range(of: Self.stateKey, in: previousCount < LoopbackRequestParser.maxRequestBytes
                    ? buffer.startIndex..<buffer.endIndex : stateWindow) != nil
                if mayCarryState,
                   LoopbackRequestParser.carriesState(String(decoding: buffer, as: UTF8.self), expectedState: self.expectedState) {
                    self.answer(connection, status: CallbackPage.selectionTooLarge.status, body: CallbackPage.selectionTooLarge.html)
                    self.finish(.failure(.requestTooLarge))
                } else if hasRequestLine || isComplete || error != nil || buffer.count >= LoopbackRequestParser.strayRequestBytes {
                    self.answer(connection, status: "413 Content Too Large", body: CallbackPage.failed.html)
                } else {
                    self.receive(connection, buffer: buffer)
                }
            } else if hasRequestLine || isComplete || error != nil {
                self.handle(String(decoding: buffer, as: UTF8.self), on: connection)
            } else if buffer.count >= LoopbackRequestParser.maxRequestBytes {
                // No request line within the size limit and not a browser redirect.
                self.answer(connection, status: "400 Bad Request", body: "")
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ connection: NWConnection, status: String, body: String) {
        _ = forget(connection)
        reply(connection, status: status, body: body)
    }

    private func handle(_ text: String, on connection: NWConnection) {
        if case .hostPort(let host, _)? = connection.currentPath?.localEndpoint {
            lock.withLock { if localHost == nil { localHost = "\(host)" } }
        }
        let callback: LoopbackCallback
        do { callback = try LoopbackRequestParser.parse(text) } catch {
            answer(connection, status: (error as? LoopbackError) == .wrongPath ? "404 Not Found" : "400 Bad Request", body: "")
            return
        }
        // A wrong state is a stray or hostile request: refuse it and keep waiting for the real redirect.
        guard let state = callback.state, LoopbackRequestParser.constantTimeEquals(state, expectedState) else {
            answer(connection, status: "400 Bad Request", body: CallbackPage.failed.html)
            return
        }
        switch Result(catching: { try LoopbackRequestParser.authorizationCode(from: callback, expectedState: expectedState) }) {
        case .failure(let error):
            answer(connection, status: "400 Bad Request", body: CallbackPage.failed.html)
            finish(.failure(error as? LoopbackError ?? .malformedRequest))
        case .success(let code):
            _ = forget(connection)
            let accepted = lock.withLock { () -> Bool in
                guard outcome == nil else { return false }
                // Only the request that delivered the code counts: a reload or prefetch must not replace the picked ids.
                acceptedCallback = callback
                callbackConnection = connection
                return true
            }
            guard accepted else { reply(connection, status: "400 Bad Request", body: CallbackPage.failed.html); return }
            finish(.success(code))
            // The page waits for `respond(_:)`; never leave the browser hanging if nobody calls it.
            queue.asyncAfter(deadline: .now() + replyTimeout) { [weak self] in self?.respond(.failed) }
        }
    }

    private func reply(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, any Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
