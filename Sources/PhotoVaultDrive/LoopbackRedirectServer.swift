import PhotoVaultCore
import Foundation
import Network

/// One-shot HTTP listener bound to 127.0.0.1 that receives the OAuth redirect (RFC 8252 section 7.3).
/// It resolves with the first callback that carries the expected `state`, then stops listening; requests
/// on other paths get a 404 and a callback with the wrong `state` gets a 400, neither consumes the slot.
/// The browser connection of the accepted callback stays open until `respond(success:)` so the page can
/// say whether the token exchange worked. Idle or slow connections are closed after `connectionTimeout`.
/// It also cancels after `timeout`.
public final class LoopbackRedirectServer: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 300

    private let expectedState: String
    private let timeout: TimeInterval
    private let connectionTimeout: TimeInterval
    private let listener: NWListener
    private let queue = DispatchQueue(label: "photovault.loopback")
    private let lock = NSLock()
    private var outcome: Result<String, LoopbackError>?
    private var waiter: CheckedContinuation<String, any Error>?
    private var localHost: String?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var callbackConnection: NWConnection?

    public init(expectedState: String, timeout: TimeInterval = LoopbackRedirectServer.defaultTimeout,
                connectionTimeout: TimeInterval = 10) throws {
        self.expectedState = expectedState
        self.timeout = timeout
        self.connectionTimeout = connectionTimeout
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        listener = try NWListener(using: parameters)
    }

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

    /// Tells the browser how the sign-in ended and closes the callback connection.
    public func respond(success: Bool) {
        let connection = lock.withLock { () -> NWConnection? in
            defer { callbackConnection = nil }
            return callbackConnection
        }
        if let connection { reply(connection, status: success ? "200 OK" : "400 Bad Request", body: success ? Self.successPage : Self.failurePage) }
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
        if !done { connections[ObjectIdentifier(connection)] = connection }
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

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: LoopbackRequestParser.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            let hasRequestLine = text.contains("\r\n")
            if hasRequestLine || isComplete || error != nil {
                self.handle(text, on: connection)
            } else if buffer.count >= LoopbackRequestParser.maxRequestBytes {
                // No request line within the size limit: not a browser redirect.
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
            answer(connection, status: "400 Bad Request", body: Self.failurePage)
            return
        }
        switch Result(catching: { try LoopbackRequestParser.authorizationCode(from: callback, expectedState: expectedState) }) {
        case .failure(let error):
            answer(connection, status: "400 Bad Request", body: Self.failurePage)
            finish(.failure(error as? LoopbackError ?? .malformedRequest))
        case .success(let code):
            _ = forget(connection)
            let accepted = lock.withLock { () -> Bool in
                guard outcome == nil else { return false }
                callbackConnection = connection
                return true
            }
            guard accepted else { reply(connection, status: "400 Bad Request", body: Self.failurePage); return }
            finish(.success(code))
            // The page waits for `respond(success:)`; never leave the browser hanging if nobody calls it.
            queue.asyncAfter(deadline: .now() + 60) { [weak self] in self?.respond(success: false) }
        }
    }

    /// Static page; nothing from the request is echoed.
    static let successPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>PhotoVault</title></head>\
    <body><p>Đã xong. Bạn có thể đóng tab này và quay lại PhotoVault.</p>\
    <p>Done. You can close this tab and return to PhotoVault.</p></body></html>
    """

    static let failurePage = """
    <!doctype html><html><head><meta charset="utf-8"><title>PhotoVault</title></head>\
    <body><p>Đăng nhập không thành công. Hãy đóng tab này và thử lại trong PhotoVault.</p>\
    <p>Sign-in failed. Close this tab and try again in PhotoVault.</p></body></html>
    """

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
