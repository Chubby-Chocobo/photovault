import Foundation

/// Per logical folder read/write locks (spec 8.9.4): file writes take the read lock of their folder,
/// folder renames the write lock of the renamed folder, which also covers everything below it.
/// Waiters are served in order so a rename cannot starve.
actor FolderLockManager {
    private struct Holder {
        let id: Int
        let path: String
        let write: Bool
    }

    private var held: [Int: Holder] = [:]
    private var waiting: [(holder: Holder, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextId = 0

    private static func affects(_ writer: String, _ other: String) -> Bool {
        writer.isEmpty || other == writer || other.hasPrefix(writer + "/")
    }

    private static func conflicts(_ a: Holder, _ b: Holder) -> Bool {
        if !a.write && !b.write { return false }
        if a.write && b.write { return affects(a.path, b.path) || affects(b.path, a.path) }
        let (writer, reader) = a.write ? (a, b) : (b, a)
        return affects(writer.path, reader.path)
    }

    func acquire(_ path: String, write: Bool) async -> Int {
        nextId += 1
        let holder = Holder(id: nextId, path: path, write: write)
        let blocked = held.values.contains { Self.conflicts($0, holder) } || waiting.contains { Self.conflicts($0.holder, holder) }
        if blocked {
            await withCheckedContinuation { waiting.append((holder, $0)) }
        } else {
            held[holder.id] = holder
        }
        return holder.id
    }

    func release(_ token: Int) {
        held[token] = nil
        var index = 0
        while index < waiting.count {
            let candidate = waiting[index].holder
            let blocked = held.values.contains { Self.conflicts($0, candidate) }
                || waiting[..<index].contains { Self.conflicts($0.holder, candidate) }
            if blocked {
                index += 1
            } else {
                held[candidate.id] = candidate
                waiting.remove(at: index).continuation.resume()
            }
        }
    }

    /// Runs `body` (synchronous file work) while holding the lock; the body runs off this actor.
    nonisolated func withLock<T: Sendable>(_ path: String, write: Bool, _ body: @Sendable () throws -> T) async throws -> T {
        let token = await acquire(path, write: write)
        do {
            let value = try body()
            await release(token)
            return value
        } catch {
            await release(token)
            throw error
        }
    }
}
