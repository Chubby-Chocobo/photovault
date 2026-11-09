import Foundation
import PhotoVaultCore

/// Machine reasons stored with an import row (`source.status_reason`).
enum SourceStatusReason {
    static let unavailable = "unavailable"
    static let signInRequired = "signInRequired"
    /// Some file waits because the scratch volume cannot take it yet.
    static let diskFull = "diskFull"
}

/// What each import has been waiting for, in memory only (a relaunch starts fresh): when a job was last
/// held, which groups wait for a retry, and since when a file has been unreadable. A folder that comes
/// and goes cannot keep the cycle busy, and one blocked group cannot hold back the others.
final class ImportHolds: @unchecked Sendable {
    /// A held job is not probed again before this much time has passed.
    static let backoff: TimeInterval = 30
    /// A job that needs the owner to sign in is probed far less often: only signing in fixes it.
    static let signInBackoff: TimeInterval = 600
    /// A file that stays unreadable for this long (wall clock) is given up on so the import can finish.
    static let giveUpAfter: TimeInterval = 24 * 3600

    enum BlockReason: Sendable { case busy, disk }

    private struct Hold { var at: Date; var wait: TimeInterval }
    private struct Block { var until: Date; var reason: BlockReason }

    private let lock = NSLock()
    private var held: [SourceID: Hold] = [:]
    private var blocked: [SourceID: [String: Block]] = [:]
    private var firstUnreadable: [SourceID: [String: Date]] = [:]

    func mark(_ id: SourceID, at date: Date, wait: TimeInterval = ImportHolds.backoff) {
        lock.withLock { held[id] = Hold(at: date, wait: wait) }
    }

    /// Forgets the job-wide hold and the group blocks (the owner signed in; try everything again).
    func clear(_ id: SourceID) {
        lock.withLock {
            held[id] = nil
            blocked[id] = nil
        }
    }

    func isCoolingDown(_ id: SourceID, now: Date) -> Bool {
        lock.withLock { held[id].map { now.timeIntervalSince($0.at) < $0.wait } ?? false }
    }

    /// The group is left pending and skipped until the cooldown has passed.
    func block(_ id: SourceID, group: String, reason: BlockReason, now: Date) {
        lock.withLock { blocked[id, default: [:]][group] = Block(until: now.addingTimeInterval(Self.backoff), reason: reason) }
    }

    /// Groups that are still waiting out their cooldown. Expired entries are dropped.
    func blockedGroups(_ id: SourceID, now: Date) -> Set<String> {
        lock.withLock {
            blocked[id] = blocked[id]?.filter { $0.value.until > now }
            return Set(blocked[id]?.keys ?? [:].keys)
        }
    }

    func isWaitingForDisk(_ id: SourceID, now: Date) -> Bool {
        lock.withLock { blocked[id]?.contains { $0.value.reason == .disk && $0.value.until > now } ?? false }
    }

    /// Notes that a file could not be read now. True once it has been unreadable for `giveUpAfter`.
    func shouldGiveUp(_ id: SourceID, path: String, now: Date) -> Bool {
        lock.withLock {
            let first = firstUnreadable[id]?[path] ?? now
            firstUnreadable[id, default: [:]][path] = first
            return now.timeIntervalSince(first) >= Self.giveUpAfter
        }
    }

    func readable(_ id: SourceID, path: String) {
        lock.withLock { _ = firstUnreadable[id]?.removeValue(forKey: path) }
    }
}
