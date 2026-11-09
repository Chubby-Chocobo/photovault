import Foundation
import os
import PhotoVaultCore

/// Runs a callback-based data request and gives up when it delivers nothing for `stallTimeout`.
///
/// iCloud downloads can stop without ever completing (sync paused, network gone quiet). Without a
/// deadline such a request would hold an export slot until the app quits. On a stall the request is
/// cancelled and the call throws `.networkError`, so the job backs off and tries again later.
/// The call returns exactly once, whether the completion, the stall or task cancellation comes first.
struct StalledRequestGuard: Sendable {
    static let defaultStallTimeout: TimeInterval = 15 * 60

    var stallTimeout: TimeInterval = Self.defaultStallTimeout
    var checkInterval: TimeInterval = 30

    private final class Outcome: @unchecked Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, Error>?
            var finished = false
            var stalled = false
            var lastActivity = Date()
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            let alreadyDone = state.withLock { s -> Bool in
                if s.finished { return true }
                s.continuation = continuation
                return false
            }
            if alreadyDone { continuation.resume(throwing: PhotosSourceError.cancelled) }
        }

        func touch() { state.withLock { $0.lastActivity = Date() } }

        func idle(longerThan limit: TimeInterval) -> Bool {
            state.withLock { !$0.finished && Date().timeIntervalSince($0.lastActivity) >= limit }
        }

        var stalled: Bool { state.withLock { $0.stalled } }

        /// Resumes the caller unless it was already resumed; returns whether this call did it.
        @discardableResult
        func finish(_ result: Result<Void, Error>, stalled: Bool = false) -> Bool {
            let continuation = state.withLock { s -> CheckedContinuation<Void, Error>? in
                guard !s.finished else { return nil }
                s.finished = true
                s.stalled = stalled
                defer { s.continuation = nil }
                return s.continuation
            }
            continuation?.resume(with: result)
            return continuation != nil
        }
    }

    /// `start` begins the request with a chunk handler and a completion; `cancel` stops it.
    func run(
        start: (_ onChunk: @escaping @Sendable (Data) -> Bool, _ completion: @escaping @Sendable (Error?) -> Void) throws -> Void,
        cancel: @escaping @Sendable () -> Void,
        onChunk: @escaping @Sendable (Data) -> Bool
    ) async throws {
        let outcome = Outcome()
        let limit = stallTimeout
        let interval = checkInterval
        let watchdog = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if outcome.idle(longerThan: limit) {
                    cancel()
                    outcome.finish(.failure(PhotosSourceError.networkError), stalled: true)
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                outcome.install(continuation)
                do {
                    try start({ data in
                        outcome.touch()
                        return onChunk(data)
                    }, { error in
                        outcome.finish(error.map { .failure($0) } ?? .success(()))
                    })
                } catch {
                    outcome.finish(.failure(error))
                }
            }
        } onCancel: {
            cancel()
            outcome.finish(.failure(PhotosSourceError.cancelled))
        }
    }
}
