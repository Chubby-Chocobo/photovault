import Foundation
import PhotoVaultCore

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { let was = done; done = true; return !was } }
}

/// What the owner asked of the running import stage, in memory and available at once: a cancel that must not wait for the
/// engine's lane, and a pause. The stage checks it between files, and a read or listing in progress is told to stop.
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
        defer { lock.withLock { _ = actions[id]?.removeValue(forKey: token) } }
        if alreadyAsked { action() }
        return try await body()
    }

    /// Runs `work` and returns its result, or nil as soon as a cancel of `id` is asked, without waiting for `work`
    /// (an adapter that ignores cancellation finishes in the background and its result is dropped).
    func untilCancelled<T: Sendable>(_ id: SourceID, _ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        let once = Once()
        let task = Task { try await work() }
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.whileReading(id, onCancel: {
                    if once.first() { task.cancel(); continuation.resume(returning: nil) }
                }) {
                    do {
                        let value = try await task.value
                        if once.first() { continuation.resume(returning: value) }
                    } catch {
                        if once.first() { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }
}
