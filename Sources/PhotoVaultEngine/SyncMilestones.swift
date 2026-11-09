import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Progress rows of the activity list (FR-63), written at the end of a cycle: how many files each
/// destination received, and once per backfill that its old photos are all backed up.
struct SyncMilestones: Sendable {
    let env: EngineEnvironment

    static func announcedKey(_ id: DestinationID) -> String { "backfill_announced.\(id.rawValue)" }

    func record(_ report: CycleReport) async throws {
        let now = env.clock.now
        let ids = await env.destinations.ids
        try await env.store.write { db in
            for id in ids {
                if let count = report.uploadedByDestination[id], count > 0 {
                    try ActivityRepository.record(db, ActivityEvent(at: now, kind: .milestone, destinationId: id, message: Self.uploadedText(count)))
                }
                try Self.noteBackfill(db, id: id, drained: report.drained, now: now)
            }
        }
    }

    /// A backfill counts as finished when none of its jobs is waiting or uploading after a cycle
    /// that ran out of work. It is announced once; new backfill work (a wider scope, a re-upload of
    /// old photos) arms the announcement again.
    static func noteBackfill(_ db: Database, id: DestinationID, drained: Bool, now: Date) throws {
        let row = try Row.fetchOne(db, sql: """
            SELECT
              SUM(state IN ('pending', 'uploading')) AS waiting,
              SUM(state = 'done') AS done,
              SUM(state = 'deferred') AS deferred
            FROM upload_job WHERE destination_id = ? AND origin IN ('backfill', 'destinationBackfill')
            """, arguments: [id.rawValue])
        let waiting: Int = row?["waiting"] ?? 0
        let done: Int = row?["done"] ?? 0
        let deferred: Int = row?["deferred"] ?? 0
        let key = announcedKey(id)
        if waiting > 0 {
            try KeyValueRepository.set(db, key, 0)
            return
        }
        guard drained, done > 0, try KeyValueRepository.int(db, key) != 1 else { return }
        try KeyValueRepository.set(db, key, 1)
        try ActivityRepository.record(db, ActivityEvent(at: now, kind: .milestone, destinationId: id, message: backfillText(done: done, deferred: deferred)))
    }

    static func uploadedText(_ count: Int) -> String {
        tr(vi: "Lần sync này đã upload \(count) file",
           en: L10n.plural(count, one: "This sync uploaded 1 file", other: "This sync uploaded \(count) files"))
    }

    static func backfillText(done: Int, deferred: Int) -> String {
        let base = tr(vi: "Đã sao lưu xong ảnh cũ: \(done) file",
                      en: L10n.plural(done, one: "Older photos are backed up: 1 file", other: "Older photos are backed up: \(done) files"))
        guard deferred > 0 else { return base }
        return base + tr(vi: " (\(deferred) file tạm hoãn vì lỗi, xem Cài đặt › Nâng cao)",
                         en: " (\(deferred) put off after errors, see Settings › Advanced)")
    }
}
