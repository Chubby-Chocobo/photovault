import Foundation
import PhotoVaultCore

/// The files being transferred right now, for the status line (export, download, upload, copy).
/// In memory only; nothing is written to the database, logs or files. Transports call the sink of
/// a `Handle` for every chunk, which costs a lock and a clock read; the list is published to
/// subscribers at most once per `minInterval`; the list filling and emptying are published at once, so a
/// finished last transfer clears the line immediately.
public final class TransferTracker: @unchecked Sendable {
    /// One running transfer. Call `end()` when it finishes or fails; calling it again does nothing.
    public struct Handle: Sendable {
        fileprivate let id: UUID
        fileprivate let tracker: TransferTracker
        public let sink: TransferSink

        public func end() { tracker.end(id) }
    }

    private let clock: any Clock
    private let minInterval: TimeInterval
    private let onPublish: (@Sendable ([TransferProgress]) -> Void)?
    private let lock = NSLock()
    private var items: [TransferProgress] = []
    private var lastPublishedAt: Date?
    private var lastPublished: [TransferProgress]?
    private var subscribers: [UUID: AsyncStream<[TransferProgress]>.Continuation] = [:]

    public init(clock: any Clock = SystemClock(), minInterval: TimeInterval = 0.5) {
        self.clock = clock
        self.minInterval = minInterval
        self.onPublish = nil
    }

    init(clock: any Clock, minInterval: TimeInterval, onPublish: @escaping @Sendable ([TransferProgress]) -> Void) {
        self.clock = clock
        self.minInterval = minInterval
        self.onPublish = onPublish
    }

    /// The transfers now, oldest first, with the latest bytes (not throttled).
    public var current: [TransferProgress] { lock.withLock { items } }

    /// Starts tracking one file. Publishes at once so a long first chunk is not invisible.
    public func begin(kind: TransferKind, fileName: String, destinationName: String? = nil, accountEmail: String? = nil, bytesTotal: Int64?) -> Handle {
        let id = UUID()
        let now = clock.now
        lock.withLock {
            items.append(TransferProgress(
                id: id, kind: kind, fileName: fileName, destinationName: destinationName, accountEmail: accountEmail,
                bytesTotal: bytesTotal, startedAt: now))
            publishLocked(at: now, force: items.count == 1)
        }
        return Handle(id: id, tracker: self, sink: TransferSink { [weak self] bytes in self?.report(id, bytes) })
    }

    /// Stream of lists; the latest published one is replayed to a new subscriber.
    public func updates() -> AsyncStream<[TransferProgress]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [TransferProgress].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.withLock {
            subscribers[id] = continuation
            if let lastPublished { continuation.yield(lastPublished) }
        }
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.subscribers[id] = nil } }
        return stream
    }

    private func report(_ id: UUID, _ bytes: Int64) {
        let now = clock.now
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].bytesDone = max(0, bytes)
            publishLocked(at: now)
        }
    }

    private func end(_ id: UUID) {
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items.remove(at: index)
            publishLocked(at: clock.now, force: items.isEmpty)
        }
    }

    /// `force` is for the list filling or emptying; every other change waits for the throttle window, so many
    /// short files do not each cost the main thread two updates.
    private func publishLocked(at now: Date, force: Bool = false) {
        if !force, let last = lastPublishedAt, now.timeIntervalSince(last) < minInterval { return }
        lastPublishedAt = now
        lastPublished = items
        for continuation in subscribers.values { continuation.yield(items) }
        onPublish?(items)
    }
}
