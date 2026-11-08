import Foundation

/// A serial dispatch queue for blocking file work (copy, fsync, hash) of one destination, so it never
/// occupies threads of the Swift concurrency pool that the engine actors need.
final class BlockingQueue: Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
