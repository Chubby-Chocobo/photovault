import Foundation

/// Streams one response to a sink with a delegate task, so large downloads never sit in memory and the
/// network is paused while the sink falls behind. Used by every cloud download (Drive and Dropbox). One
/// session serves all downloads, so connections to the provider are reused; the delegate routes each
/// task's events to its own stream.
final class URLSessionStreamer: @unchecked Sendable {
    /// Bytes of an error body kept for the caller.
    static let maxErrorBody = 1 << 16
    /// The network is paused above this much unprocessed data and resumed below the low mark.
    static let highWater = 8 << 20
    static let lowWater = 2 << 20

    private let configuration: URLSessionConfiguration
    private let router = Router()
    private let lock = NSLock()
    private var shared: URLSession?

    init(configuration: URLSessionConfiguration) { self.configuration = configuration }

    deinit { shared?.finishTasksAndInvalidate() }

    private var session: URLSession {
        lock.withLock {
            if let shared { return shared }
            let made = URLSession(configuration: configuration, delegate: router, delegateQueue: nil)
            shared = made
            return made
        }
    }

    /// 2xx: the body goes to `sink` in order and the returned data is empty. Any other status: the sink
    /// is never called and the data is the start of the body. A throwing sink stops the transfer and its error
    /// propagates; a cancelled task throws `CancellationError`, never a short body reported as complete.
    func stream(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self)
        let flow = Flow()
        let task = session.dataTask(with: request)
        flow.task = task
        let identifier = task.taskIdentifier
        router.register(identifier, Route(continuation: continuation, flow: flow))
        continuation.onTermination = { [router] _ in
            router.unregister(identifier)
            task.cancel()
        }
        task.resume()
        var head: HTTPURLResponse?
        var errorBody = Data()
        var completed = false
        for try await event in events {
            try Task.checkCancellation()
            switch event {
            case .head(let response): head = response
            case .data(let data):
                if let head, (200..<300).contains(head.statusCode) {
                    try sink(data)
                } else if errorBody.count < Self.maxErrorBody {
                    errorBody.append(data.prefix(Self.maxErrorBody - errorBody.count))
                }
                flow.consumed(data.count)
            case .completed: completed = true
            }
        }
        // Cancelling the consuming task ends the loop without an error: that is not a finished download.
        try Task.checkCancellation()
        guard completed else { throw CancellationError() }
        guard let head else { throw URLError(.badServerResponse) }
        return (errorBody, head)
    }

    private enum Event: @unchecked Sendable {
        case head(HTTPURLResponse)
        case data(Data)
        case completed
    }

    /// Counts the bytes received and not yet handled; pauses the task when the sink is far behind.
    private final class Flow: @unchecked Sendable {
        private let lock = NSLock()
        private var buffered = 0
        private var paused = false
        var task: URLSessionTask?

        func received(_ count: Int) {
            lock.withLock {
                buffered += count
                if buffered > URLSessionStreamer.highWater, !paused {
                    paused = true
                    task?.suspend()
                }
            }
        }

        func consumed(_ count: Int) {
            lock.withLock {
                buffered -= count
                if paused, buffered <= URLSessionStreamer.lowWater {
                    paused = false
                    task?.resume()
                }
            }
        }
    }

    private struct Route {
        var continuation: AsyncThrowingStream<Event, any Error>.Continuation
        var flow: Flow
    }

    private final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [Int: Route] = [:]

        func register(_ identifier: Int, _ route: Route) { lock.withLock { routes[identifier] = route } }
        func unregister(_ identifier: Int) { lock.withLock { routes[identifier] = nil } }
        private func route(_ identifier: Int) -> Route? { lock.withLock { routes[identifier] } }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let route = route(dataTask.taskIdentifier) else { completionHandler(.cancel); return }
            if let http = response as? HTTPURLResponse { route.continuation.yield(.head(http)) }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let route = route(dataTask.taskIdentifier) else { return }
            route.flow.received(data.count)
            route.continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let route = route(task.taskIdentifier) else { return }
            unregister(task.taskIdentifier)
            if let error { route.continuation.finish(throwing: error) } else {
                route.continuation.yield(.completed)
                route.continuation.finish()
            }
        }
    }
}
