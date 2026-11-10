import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// What the app shows once a backfill has ended: a one-time record, not live progress.
public struct BackfillCompletionSummary: Sendable, Equatable {
    /// Nil only for a backfill that finished before the app began recording its end and left no job time.
    public var completedAt: Date?
    public var assets: Int
    public var bytes: Int64
    /// The macOS notification is still to be posted (and acknowledged).
    public var notificationPending: Bool

    /// "1.200 ảnh · 3,0 GB": counts and size only.
    public var countsText: String { BackfillCompletion.countsText(assets: assets, bytes: bytes) }
}

/// A backfill ends once: the end is detected at the close of a drained cycle, and its marker, activity
/// row and notification flag are written in one transaction. `completed_jobs` is the number of
/// finished backfill jobs at the last end, so a relaunch or a later cycle repeats nothing, while a new
/// backfill (a destination added afterwards) ends again.
enum BackfillCompletion {
    enum Key {
        static let completedJobs = "backfill.completed_jobs"
        static let completedAt = "backfill.completed_at"
        static let completedAssets = "backfill.completed_assets"
        static let completedBytes = "backfill.completed_bytes"
        static let notifyPending = "backfill.notify_pending"
    }

    private static let origins = "'backfill', 'destinationBackfill'"

    static var activityPrefix: String { tr(vi: "Backfill xong", en: "Backfill finished") }

    static func countsText(assets: Int, bytes: Int64) -> String {
        let count = L10n.integer(assets)
        let photos = tr(vi: "\(count) ảnh", en: L10n.plural(assets, one: "1 photo", other: "\(count) photos"))
        return photos + " · " + SizeText.bytes(bytes)
    }

    static func activityText(assets: Int, bytes: Int64) -> String { activityPrefix + ": " + countsText(assets: assets, bytes: bytes) }

    /// Records the end of a backfill when one just finished.
    static func note(_ db: Database, drained: Bool, now: Date) throws {
        guard drained, try isFinished(db) else { return }
        let jobs = try doneJobs(db)
        guard jobs > (try KeyValueRepository.int(db, Key.completedJobs) ?? 0) else { return }
        let state = try counts(db)
        try store(db, jobs: jobs, at: now, state: state, pending: true)
        try ActivityRepository.record(db, ActivityEvent(at: now, kind: .milestone, message: activityText(assets: state.assets, bytes: state.bytes)))
    }

    /// A backfill that finished before the end was recorded: mark it without a notification or an
    /// activity row. Runs once per launch, before the first cycle's work.
    static func markEarlierBackfill(_ db: Database) throws {
        guard try KeyValueRepository.int(db, Key.completedJobs) == nil, try isFinished(db) else { return }
        let jobs = try doneJobs(db)
        guard jobs > 0 else { return }
        let finishedAt = try Date.fetchOne(db, sql: "SELECT MAX(updated_at) FROM upload_job WHERE state = 'done' AND origin IN (\(origins))")
        try store(db, jobs: jobs, at: finishedAt, state: try counts(db), pending: false)
    }

    static func acknowledgeNotification(_ db: Database) throws {
        try KeyValueRepository.set(db, Key.notifyPending, 0)
    }

    static func summary(_ db: Database) throws -> BackfillCompletionSummary? {
        guard let assets = try KeyValueRepository.int(db, Key.completedAssets) else { return nil }
        return BackfillCompletionSummary(
            completedAt: try KeyValueRepository.date(db, Key.completedAt), assets: assets,
            bytes: Int64(try KeyValueRepository.int(db, Key.completedBytes) ?? 0),
            notificationPending: (try KeyValueRepository.int(db, Key.notifyPending) ?? 0) == 1)
    }

    // MARK: Queries

    /// Every backfill job is closed, at least one exists, and no old photo waits to be classified.
    private static func isFinished(_ db: Database) throws -> Bool {
        let progress = try SnapshotCounterRepository.backfillProgress(db)
        guard progress.total > 0, progress.done == progress.total else { return false }
        return try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(SELECT 1 FROM asset WHERE category_provisional = 1 AND deleted_at IS NULL)") ?? false
    }

    private static func doneJobs(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM upload_job WHERE state = 'done' AND origin IN (\(origins))") ?? 0
    }

    private static func counts(_ db: Database) throws -> (assets: Int, bytes: Int64) {
        let bytes = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(b.bytes), 0) FROM job_bytes b JOIN upload_job j ON j.id = b.job_id WHERE j.origin IN (\(origins))
            """) ?? 0
        return (try SnapshotCounterRepository.backfillProgress(db).total, bytes)
    }

    private static func store(_ db: Database, jobs: Int, at date: Date?, state: (assets: Int, bytes: Int64), pending: Bool) throws {
        try KeyValueRepository.set(db, Key.completedJobs, jobs)
        try KeyValueRepository.set(db, Key.completedAt, date)
        try KeyValueRepository.set(db, Key.completedAssets, state.assets)
        try KeyValueRepository.set(db, Key.completedBytes, Int(state.bytes))
        try KeyValueRepository.set(db, Key.notifyPending, pending ? 1 : 0)
    }
}
