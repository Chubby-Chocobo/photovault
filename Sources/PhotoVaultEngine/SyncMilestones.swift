import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Progress rows of the activity list (FR-63), written at the end of a cycle: one row per destination
/// and day that counts the files uploaded, and one row when a destination's old photos are all
/// backed up.
struct SyncMilestones: Sendable {
    let env: EngineEnvironment

    static func announcedTotalKey(_ id: DestinationID) -> String { "activity_row.backfillTotal.\(id.rawValue)" }

    /// Never fails the cycle: progress rows are a convenience.
    func record(_ report: CycleReport) async {
        let env = env
        let ids = await env.destinations.ids
        await Task {
            let now = env.clock.now
            do {
                try await env.store.write { db in
                    for id in ids {
                        if let count = report.uploadedByDestination[id], count > 0 {
                            try Self.noteUploads(db, id: id, count: count, now: now)
                        }
                        try Self.noteBackfill(db, id: id, drained: report.drained, now: now)
                    }
                }
            } catch {
                env.log.log(.error, category: "activity", "could not record sync progress")
            }
        }.value
    }

    static func noteUploads(_ db: Database, id: DestinationID, count: Int, now: Date, calendar: Calendar = .current) throws {
        try ActivityRepository.recordCoalesced(
            db, group: "uploaded", kind: .milestone, destinationId: id, count: count, now: now,
            sameWindow: { calendar.isDate($0, inSameDayAs: now) }, message: uploadedText)
    }

    /// Announced when, after a cycle that ran out of work, no old photo waits to be classified and no
    /// backfill job waits or uploads, and the destination has more finished backfill jobs than at the
    /// last announcement (so a deferred file that comes back, or a retry, does not repeat it).
    static func noteBackfill(_ db: Database, id: DestinationID, drained: Bool, now: Date) throws {
        guard drained else { return }
        let busy = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM upload_job WHERE state IN ('pending', 'uploading') AND destination_id = ?
                            AND origin IN ('backfill', 'destinationBackfill'))
                OR EXISTS(SELECT 1 FROM asset WHERE category_provisional = 1 AND deleted_at IS NULL)
            """, arguments: [id.rawValue]) ?? true
        guard !busy else { return }
        let row = try Row.fetchOne(db, sql: """
            SELECT SUM(state = 'done') AS done, SUM(state = 'deferred') AS deferred
            FROM upload_job WHERE destination_id = ? AND origin IN ('backfill', 'destinationBackfill')
            """, arguments: [id.rawValue])
        let done: Int = row?["done"] ?? 0
        let deferred: Int = row?["deferred"] ?? 0
        let key = announcedTotalKey(id)
        guard done > (try KeyValueRepository.int(db, key) ?? 0) else { return }
        try KeyValueRepository.set(db, key, done)
        try ActivityRepository.record(db, ActivityEvent(at: now, kind: .milestone, destinationId: id, message: backfillText(done: done, deferred: deferred)))
    }

    static func uploadedText(_ count: Int) -> String {
        tr(vi: "Hôm nay đã upload \(L10n.integer(count)) file",
           en: L10n.plural(count, one: "1 file uploaded today", other: "\(L10n.integer(count)) files uploaded today"))
    }

    static func backfillText(done: Int, deferred: Int) -> String {
        let base = tr(vi: "Đã sao lưu xong ảnh cũ: \(L10n.integer(done)) file",
                      en: L10n.plural(done, one: "Older photos are backed up: 1 file", other: "Older photos are backed up: \(L10n.integer(done)) files"))
        guard deferred > 0 else { return base }
        return base + tr(vi: " (\(L10n.integer(deferred)) file tạm hoãn vì lỗi, xem Cài đặt › Nâng cao)",
                         en: " (\(L10n.integer(deferred)) deferred after errors, see Settings › Advanced)")
    }
}
