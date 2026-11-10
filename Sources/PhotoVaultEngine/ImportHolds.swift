import Foundation
import PhotoVaultCore

/// Machine reasons stored with an import row (`source.status_reason`).
enum SourceStatusReason {
    static let unavailable = "unavailable"
    static let signInRequired = "signInRequired"
    /// Some file waits because the scratch volume cannot take it yet.
    static let diskFull = "diskFull"
}

/// What each import has been waiting for, in memory (the failure count and first failure time of a group are also
/// stored with its items, so a relaunch carries on): when a job was last
/// held, which groups wait for a retry, and how long a group has been failing. A folder that comes
/// and goes cannot keep the cycle busy, and a stubborn group cannot hold back the others.
final class ImportHolds: @unchecked Sendable {
    /// A held job is not probed again before this much time has passed.
    static let backoff: TimeInterval = 30
    /// A job that needs the owner to sign in is probed far less often: only signing in fixes it.
    static let signInBackoff: TimeInterval = 600
    /// A group that cannot be read is tried again after `backoff`, then twice as long each time, up to this.
    static let maxGroupBackoff: TimeInterval = 3600
    /// A group is given up when it has failed this many times and this long has passed between its first
    /// and its latest failure (wall clock).
    static let giveUpAfterTries = 10
    static let giveUpAfter: TimeInterval = 24 * 3600
    /// After this many fresh groups in a row that fail to read, the pass stops (the provider is in trouble).
    static let troubleStreak = 3

    private struct Hold { var at: Date; var wait: TimeInterval }
    private struct Failing { var first: Date; var last: Date; var tries: Int; var retryAt: Date }

    /// What one more failure of a group means.
    struct Failure: Equatable {
        /// The group has failed long and often enough to be given up now.
        var giveUp: Bool
        /// No earlier failure of this group was recorded.
        var isFresh: Bool
        /// Failures so far, this one included, and the time of the first.
        var tries: Int
        var first: Date
    }

    /// Failures of a group stored before this run began (see `ImportItemRepository.recordFailure`).
    struct Prior: Equatable {
        var tries: Int
        var first: Date
    }

    private let lock = NSLock()
    private var held: [SourceID: Hold] = [:]
    private var diskBlocked: [SourceID: [String: Date]] = [:]
    private var failing: [SourceID: [String: Failing]] = [:]

    func mark(_ id: SourceID, at date: Date, wait: TimeInterval = ImportHolds.backoff) {
        lock.withLock { held[id] = Hold(at: date, wait: wait) }
    }

    /// Forgets the job-wide hold and every group's waiting (the owner signed in; try everything again).
    func clear(_ id: SourceID) {
        lock.withLock {
            held[id] = nil
            diskBlocked[id] = nil
            failing[id] = nil
        }
    }

    func isCoolingDown(_ id: SourceID, now: Date) -> Bool {
        lock.withLock { held[id].map { now.timeIntervalSince($0.at) < $0.wait } ?? false }
    }

    /// The group is left pending and skipped until the cooldown has passed: the scratch volume has no room for it.
    func blockForDisk(_ id: SourceID, group: String, now: Date) {
        lock.withLock { diskBlocked[id, default: [:]][group] = now.addingTimeInterval(Self.backoff) }
    }

    /// Groups that are still waiting for disk room. Expired entries are dropped.
    func diskBlockedGroups(_ id: SourceID, now: Date) -> Set<String> {
        lock.withLock {
            diskBlocked[id] = diskBlocked[id]?.filter { $0.value > now }
            return Set(diskBlocked[id]?.keys ?? [:].keys)
        }
    }

    func isWaitingForDisk(_ id: SourceID, now: Date) -> Bool {
        lock.withLock { diskBlocked[id]?.contains { $0.value > now } ?? false }
    }

    /// Groups that have failed before, soonest retry first, and the ones among them whose retry time has come.
    func failingGroups(_ id: SourceID, now: Date) -> (all: [String], due: [String]) {
        lock.withLock {
            let sorted = (failing[id] ?? [:]).sorted { ($0.value.retryAt, $0.key) < ($1.value.retryAt, $1.key) }
            return (sorted.map(\.key), sorted.filter { $0.value.retryAt <= now }.map(\.key))
        }
    }

    /// Notes that a group could not be read now and schedules its next try.
    /// Without an entry in memory (the app was relaunched), the stored count and first time carry on.
    func noteFailure(_ id: SourceID, group: String, now: Date, prior: Prior? = nil) -> Failure {
        lock.withLock {
            let old = failing[id]?[group] ?? prior.map { Failing(first: $0.first, last: $0.first, tries: $0.tries, retryAt: now) }
            let tries = (old?.tries ?? 0) + 1
            let wait = min(Self.backoff * pow(2, Double(tries - 1)), Self.maxGroupBackoff)
            let entry = Failing(first: old?.first ?? now, last: now, tries: tries, retryAt: now.addingTimeInterval(wait))
            failing[id, default: [:]][group] = entry
            return Failure(
                giveUp: tries >= Self.giveUpAfterTries && now.timeIntervalSince(entry.first) >= Self.giveUpAfter, isFresh: old == nil,
                tries: tries, first: entry.first)
        }
    }

    /// The group was decided (committed or given up): its failures are forgotten.
    func settled(_ id: SourceID, group: String) {
        lock.withLock { _ = failing[id]?.removeValue(forKey: group) }
    }
}
