import Foundation

/// A dispatch queue for blocking file work of one destination, so it never occupies threads of the
/// Swift concurrency pool that the engine actors need. The bulk queue is serial (one copy at a time);
/// the metadata queue is concurrent so probes and health checks never wait behind a copy.
final class BlockingQueue: Sendable {
    private let queue: DispatchQueue

    init(label: String, concurrent: Bool = false) {
        queue = DispatchQueue(label: label, qos: .utility, attributes: concurrent ? .concurrent : [])
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
