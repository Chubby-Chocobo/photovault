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
/// row and notification flag are written in one transaction. `completed_max_job` is the highest id of
/// the (non-cancelled) backfill jobs at the last end. Job ids only grow, so a relaunch, a retried
/// skipped file or a deleted finished job repeats or hides nothing, while a new backfill (a destination
/// added or added again) creates higher ids and ends again.
enum BackfillCompletion {
    enum Key {
        static let completedMaxJob = "backfill.completed_max_job"
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
    static func note(_ db: Database, drained: Bool, now: Date, settings: SettingsSnapshot) throws {
        guard drained, let latest = try latestJobId(db), latest > (try recordedJobId(db)) else { return }
        guard try isFinished(db, settings: settings) else { return }
        let state = try counts(db, after: try recordedJobId(db))
        guard state.assets > 0 else { return }
        try store(db, latestJob: latest, at: now, state: state, pending: true)
        try ActivityRepository.record(db, ActivityEvent(at: now, kind: .milestone, message: activityText(assets: state.assets, bytes: state.bytes)))
    }

    /// A backfill that finished before the end was recorded: mark it without a notification or an
    /// activity row. Runs once per launch, before the first cycle's work.
    static func markEarlierBackfill(_ db: Database, settings: SettingsSnapshot) throws {
        guard try KeyValueRepository.int(db, Key.completedMaxJob) == nil, let latest = try latestJobId(db),
              try isFinished(db, settings: settings) else { return }
        let state = try counts(db, after: 0)
        guard state.assets > 0 else { return }
        let finishedAt = try Date.fetchOne(db, sql: "SELECT MAX(updated_at) FROM upload_job WHERE state = 'done' AND origin IN (\(origins))")
        try store(db, latestJob: latest, at: finishedAt, state: state, pending: false)
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

    private static func recordedJobId(_ db: Database) throws -> Int64 {
        Int64(try KeyValueRepository.int(db, Key.completedMaxJob) ?? 0)
    }

    /// Highest id of the backfill jobs of destinations the owner has not paused. A paused destination's
    /// jobs are left out so that the work it does after it resumes is recorded as its own end.
    private static func latestJobId(_ db: Database) throws -> Int64? {
        let paused = try pausedDestinations(db)
        let marks = paused.map { _ in "?" }.joined(separator: ", ")
        let skip = paused.isEmpty ? "" : " AND destination_id NOT IN (\(marks))"
        return try Int64.fetchOne(
            db, sql: "SELECT MAX(id) FROM upload_job WHERE origin IN (\(origins)) AND state != 'cancelled'\(skip)",
            arguments: StatementArguments(paused))
    }

    private static func pausedDestinations(_ db: Database) throws -> [String] {
        try DestinationRepository.fetchAll(db).filter { $0.status == .paused(.userPaused) }.map(\.id.rawValue)
    }

    /// Every backfill job (of a destination the owner has not paused) is closed, at least one exists,
    /// and no old photo that some destination still needs classified is waiting. Photos outside every
    /// destination's scope, or that the settings exclude, stay provisional for good and do not count.
    private static func isFinished(_ db: Database, settings: SettingsSnapshot) throws -> Bool {
        let progress = try EngineQueries.backfillProgress(db)
        guard progress.total > 0, progress.done == progress.total else { return false }
        let destinations = try DestinationRepository.fetchAll(db)
        let scope = ClassifyScope(destinations: destinations)
        var cursor: EngineQueries.ProvisionalCursor?
        while true {
            let page = try EngineQueries.provisionalPage(db, after: cursor, limit: 200, scope: scope)
            guard let last = page.last else { return true }
            cursor = last.cursor
            for entry in page {
                guard let asset = try AssetRepository.fetch(db, key: entry.key), asset.sourceId == .photos else { continue }
                if Eligibility.needsClassification(asset, destinations: destinations, settings: settings.settings, archiveTimeZone: settings.timeZone) {
                    return false
                }
            }
        }
    }

    /// Photos with a finished backfill job after `jobId`, and the bytes those jobs uploaded.
    private static func counts(_ db: Database, after jobId: Int64) throws -> (assets: Int, bytes: Int64) {
        let assets = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT asset_key) FROM upload_job WHERE state = 'done' AND origin IN (\(origins)) AND id > ?
            """, arguments: [jobId]) ?? 0
        let bytes = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(b.bytes), 0) FROM job_bytes b JOIN upload_job j ON j.id = b.job_id
            WHERE j.origin IN (\(origins)) AND j.id > ?
            """, arguments: [jobId]) ?? 0
        return (assets, bytes)
    }

    private static func store(_ db: Database, latestJob: Int64, at date: Date?, state: (assets: Int, bytes: Int64), pending: Bool) throws {
        try KeyValueRepository.set(db, Key.completedMaxJob, Int(latestJob))
        try KeyValueRepository.set(db, Key.completedAt, date)
        try KeyValueRepository.set(db, Key.completedAssets, state.assets)
        try KeyValueRepository.set(db, Key.completedBytes, Int(state.bytes))
        try KeyValueRepository.set(db, Key.notifyPending, pending ? 1 : 0)
    }
}
