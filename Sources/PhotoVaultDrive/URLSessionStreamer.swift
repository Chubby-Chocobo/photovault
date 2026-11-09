import Foundation

/// Streams one response to a sink with a delegate task, so large downloads never sit in memory and the
/// network is paused while the sink falls behind. Used by every cloud download (Drive and Dropbox).
struct URLSessionStreamer {
    /// Bytes of an error body kept for the caller.
    static let maxErrorBody = 1 << 16
    /// The network is paused above this much unprocessed data and resumed below the low mark.
    static let highWater = 8 << 20
    static let lowWater = 2 << 20

    let configuration: URLSessionConfiguration

    /// 2xx: the body goes to `sink` in order and the returned data is empty. Any other status: the sink
    /// is never called and the data is the start of the body. A throwing sink stops the transfer and its error
    /// propagates; a cancelled task throws `CancellationError`, never a short body reported as complete.
    func stream(_ request: URLRequest, sink: @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self)
        let flow = Flow()
        let session = URLSession(configuration: configuration, delegate: Delegate(continuation, flow), delegateQueue: nil)
        let task = session.dataTask(with: request)
        flow.task = task
        continuation.onTermination = { _ in
            task.cancel()
            session.finishTasksAndInvalidate()
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

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<Event, any Error>.Continuation
        private let flow: Flow

        init(_ continuation: AsyncThrowingStream<Event, any Error>.Continuation, _ flow: Flow) {
            self.continuation = continuation
            self.flow = flow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse { continuation.yield(.head(http)) }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            flow.received(data.count)
            continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error { continuation.finish(throwing: error) } else {
                continuation.yield(.completed)
                continuation.finish()
            }
        }
    }
}
