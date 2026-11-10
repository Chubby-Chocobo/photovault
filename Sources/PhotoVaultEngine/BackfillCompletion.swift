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
/// row and notification flag are written in one transaction. `completed_marks` maps each destination to
/// the highest id of its (non-cancelled) backfill jobs at the last end. Job ids only grow, so a
/// relaunch, a retried skipped file or a deleted finished job repeats or hides nothing, while a new
/// backfill (a destination added or added again) creates higher ids and ends again. The marks are per
/// destination because fan-out interleaves the ids of destinations: a destination the owner paused
/// keeps its old mark, and what it uploads after it resumes is an end of its own.
enum BackfillCompletion {
    enum Key {
        static let completedMarks = "backfill.completed_marks"
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
        guard drained else { return }
        let marks = try recordedMarks(db) ?? [:]
        let latest = try latestJobIds(db)
        guard latest.contains(where: { $0.value > (marks[$0.key] ?? 0) }), try isFinished(db, settings: settings) else { return }
        let state = try counts(db, after: marks)
        guard state.assets > 0 else { return }
        try store(db, marks: merged(marks, latest, db), at: now, state: state, pending: true)
        try ActivityRepository.record(db, ActivityEvent(at: now, kind: .milestone, message: activityText(assets: state.assets, bytes: state.bytes)))
    }

    /// A backfill that finished before the end was recorded: mark it without a notification or an
    /// activity row. Runs once per launch, before the first cycle's work.
    static func markEarlierBackfill(_ db: Database, settings: SettingsSnapshot) throws {
        guard try recordedMarks(db) == nil, try isFinished(db, settings: settings) else { return }
        let latest = try latestJobIds(db)
        let state = try counts(db, after: [:])
        guard !latest.isEmpty, state.assets > 0 else { return }
        let finishedAt = try Date.fetchOne(db, sql: "SELECT MAX(updated_at) FROM upload_job WHERE state = 'done' AND origin IN (\(origins))")
        try store(db, marks: merged([:], latest, db), at: finishedAt, state: state, pending: false)
    }

    /// Files that recovery matched to what the destination already holds are written as finished backfill
    /// jobs although nothing was uploaded. Moves the destination's mark past them, with no row and no
    /// notification, so only what is uploaded afterwards counts as a backfill. Jobs still open keep
    /// their place: the mark stops before the first of them.
    static func skipRecovered(_ db: Database, destinationId: String) throws {
        let id = try Int64.fetchOne(db, sql: """
            SELECT MAX(id) FROM upload_job
            WHERE destination_id = ?1 AND origin IN (\(origins)) AND state = 'done'
              AND id < COALESCE((SELECT MIN(id) FROM upload_job
                                 WHERE destination_id = ?1 AND origin IN (\(origins))
                                   AND state IN ('pending', 'uploading', 'deferred', 'missingRemote')), 9223372036854775807)
            """, arguments: [destinationId])
        guard let id else { return }
        var marks = try recordedMarks(db) ?? [:]
        guard id > (marks[destinationId] ?? 0) else { return }
        marks[destinationId] = id
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try KeyValueRepository.set(db, Key.completedMarks, String(decoding: try encoder.encode(marks), as: UTF8.self))
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

    /// nil until the first end (or the upgrade mark) was stored.
    private static func recordedMarks(_ db: Database) throws -> [String: Int64]? {
        guard let text = try KeyValueRepository.string(db, Key.completedMarks), let data = text.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode([String: Int64].self, from: data)
    }

    /// Highest non-cancelled backfill job id per destination the owner has not paused.
    private static func latestJobIds(_ db: Database) throws -> [String: Int64] {
        let paused = Set(try pausedDestinations(db))
        let rows = try Row.fetchAll(db, sql: """
            SELECT destination_id, MAX(id) AS last FROM upload_job
            WHERE origin IN (\(origins)) AND state != 'cancelled' GROUP BY destination_id
            """)
        var result: [String: Int64] = [:]
        for row in rows {
            let id: String = row["destination_id"]
            if !paused.contains(id) { result[id] = row["last"] }
        }
        return result
    }

    /// The stored marks after an end: the active destinations move to their latest job, the others
    /// (paused ones) keep their old mark, and destinations that no longer exist are dropped.
    private static func merged(_ marks: [String: Int64], _ latest: [String: Int64], _ db: Database) throws -> [String: Int64] {
        let existing = Set(try DestinationRepository.fetchAll(db).map(\.id.rawValue))
        var result = marks.filter { existing.contains($0.key) }
        for (id, last) in latest where existing.contains(id) { result[id] = last }
        return result
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

    /// Photos with a finished backfill job past its destination's mark, and the bytes those jobs uploaded.
    private static func counts(_ db: Database, after marks: [String: Int64]) throws -> (assets: Int, bytes: Int64) {
        let ordered = marks.sorted { $0.key < $1.key }
        var arguments: [any DatabaseValueConvertible] = []
        var terms: [String] = []
        for (id, mark) in ordered {
            terms.append("(j.destination_id = ? AND j.id > ?)")
            arguments += [id, mark]
        }
        if ordered.isEmpty {
            terms.append("1")
        } else {
            terms.append("j.destination_id NOT IN (\(ordered.map { _ in "?" }.joined(separator: ", ")))")
            arguments += ordered.map(\.key)
        }
        let past = "(" + terms.joined(separator: " OR ") + ")"
        let assets = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT j.asset_key) FROM upload_job j WHERE j.state = 'done' AND j.origin IN (\(origins)) AND \(past)
            """, arguments: StatementArguments(arguments)) ?? 0
        let bytes = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(b.bytes), 0) FROM job_bytes b JOIN upload_job j ON j.id = b.job_id
            WHERE j.origin IN (\(origins)) AND \(past)
            """, arguments: StatementArguments(arguments)) ?? 0
        return (assets, bytes)
    }

    private static func store(_ db: Database, marks: [String: Int64], at date: Date?, state: (assets: Int, bytes: Int64), pending: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try KeyValueRepository.set(db, Key.completedMarks, String(decoding: try encoder.encode(marks), as: UTF8.self))
        try KeyValueRepository.set(db, Key.completedAt, date)
        try KeyValueRepository.set(db, Key.completedAssets, state.assets)
        try KeyValueRepository.set(db, Key.completedBytes, Int(state.bytes))
        try KeyValueRepository.set(db, Key.notifyPending, pending ? 1 : 0)
    }
}
