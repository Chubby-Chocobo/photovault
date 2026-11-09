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
    /// A group that keeps failing is given up on so the import can finish, but only once both limits are
    /// reached: this much wall-clock time since its first failure and this many failed tries.
    static let giveUpAfter: TimeInterval = 24 * 3600
    static let giveUpAfterTries = 10
    /// Failures further apart than this are not one streak: time with no tries does not count.
    static let streakGap: TimeInterval = 2 * 3600
    /// After this many groups in a row that end busy or unreachable, the pass stops (the provider is in trouble).
    static let troubleStreak = 3

    enum BlockReason: Sendable { case busy, disk }

    private struct Hold { var at: Date; var wait: TimeInterval }
    private struct Block { var until: Date; var reason: BlockReason }

    private let lock = NSLock()
    private var held: [SourceID: Hold] = [:]
    private var blocked: [SourceID: [String: Block]] = [:]
    private struct Streak { var first: Date; var last: Date; var tries: Int }
    private var failing: [SourceID: [String: Streak]] = [:]

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

    /// Notes that a group could not be read now. True once it has failed for `giveUpAfter` and at least
    /// `giveUpAfterTries` times; a failure long after the previous one starts the count again. A streak
    /// begins only when `startsStreak` is true (the pass could read something else), so an outage that
    /// hits every file never starts one.
    func noteFailure(_ id: SourceID, group: String, now: Date, startsStreak: Bool = true) -> Bool {
        lock.withLock {
            var streak = failing[id]?[group]
            if let old = streak, now.timeIntervalSince(old.last) > Self.streakGap { streak = nil }
            guard var current = streak ?? (startsStreak ? Streak(first: now, last: now, tries: 0) : nil) else {
                failing[id]?[group] = nil
                return false
            }
            current.last = now
            current.tries += 1
            failing[id, default: [:]][group] = current
            return now.timeIntervalSince(current.first) >= Self.giveUpAfter && current.tries >= Self.giveUpAfterTries
        }
    }

    /// The group was decided (committed or given up): its failures are forgotten.
    func settled(_ id: SourceID, group: String) {
        lock.withLock { _ = failing[id]?.removeValue(forKey: group) }
    }
}
