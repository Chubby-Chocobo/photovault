import Foundation
import PhotoVaultCore

/// Hands one result to a continuation exactly once, whichever side (the work, a cancel, the caller's cancellation) comes first.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, any Error>?
    private var finished: Result<T?, any Error>?

    func attach(_ continuation: CheckedContinuation<T?, any Error>) {
        let ready = lock.withLock { () -> Result<T?, any Error>? in
            if finished == nil { self.continuation = continuation }
            return finished
        }
        if let ready { continuation.resume(with: ready) }
    }

    func finish(_ result: Result<T?, any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<T?, any Error>? in
            guard finished == nil else { return nil }
            finished = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}

/// What the owner asked of the running import stage and export pass, in memory and available at once: a cancel that must not
/// wait for the engine's lane, and a pause. Both check it between files, and a read or listing in progress is told to stop.
/// The cancel is also stored (`SourceConfig.cancelRequested`) so a relaunch honours it.
final class ImportInterrupts: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Set<SourceID> = []
    private var actions: [SourceID: [UUID: @Sendable () -> Void]] = [:]
    private var pauseFlag = false

    var paused: Bool {
        get { lock.withLock { pauseFlag } }
        set { lock.withLock { pauseFlag = newValue } }
    }

    /// Marks `id` cancelled and stops what is reading for it right now.
    func requestCancel(_ id: SourceID) {
        let running = lock.withLock { () -> [@Sendable () -> Void] in
            cancelled.insert(id)
            return Array((actions[id] ?? [:]).values)
        }
        running.forEach { $0() }
    }

    func isCancelRequested(_ id: SourceID) -> Bool { lock.withLock { cancelled.contains(id) } }

    /// The bookkeeping of the cancel is done; the stored row speaks for itself from now on.
    func clearCancel(_ id: SourceID) { lock.withLock { _ = cancelled.remove(id) } }

    /// Runs `body`; a cancel of `id` meanwhile (or already asked) calls `action`.
    func whileReading<T>(_ id: SourceID, onCancel action: @escaping @Sendable () -> Void, _ body: () async throws -> T) async rethrows -> T {
        let token = UUID()
        let alreadyAsked = lock.withLock { () -> Bool in
            actions[id, default: [:]][token] = action
            return cancelled.contains(id)
        }
        defer {
            lock.withLock {
                actions[id]?[token] = nil
                if actions[id]?.isEmpty == true { actions[id] = nil }
            }
        }
        if alreadyAsked { action() }
        return try await body()
    }

    /// Runs `work` and returns its result, or nil as soon as a cancel of `id` is asked, without waiting for `work`
    /// (an adapter that ignores cancellation finishes in the background and its result is dropped). When the calling task
    /// is cancelled, the wait ends with `CancellationError` and `work` is cancelled too.
    func untilCancelled<T: Sendable>(_ id: SourceID, _ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        let race = Race<T>()
        let task = Task { try await work() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, any Error>) in
                race.attach(continuation)
                Task {
                    await self.whileReading(id, onCancel: {
                        task.cancel()
                        race.finish(.success(nil))
                    }) {
                        do { race.finish(.success(try await task.value)) } catch { race.finish(.failure(error)) }
                    }
                }
            }
        } onCancel: {
            task.cancel()
            race.finish(.failure(CancellationError()))
        }
    }
}
