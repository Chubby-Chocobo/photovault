import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Progress rows of the activity list (FR-63), written at the end of a cycle: one row per destination
/// and day that counts the files uploaded, and one row when a backfill ends (`BackfillCompletion`).
/// A drained cycle also finishes the backfill runs of the history that have nothing left to send.
struct SyncMilestones: Sendable {
    let env: EngineEnvironment

    /// Never fails the cycle: progress rows are a convenience.
    func record(_ report: CycleReport) async {
        let env = env
        let ids = await env.destinations.ids
        let settings = await env.settingsSnapshot()
        await Task {
            let now = env.clock.now
            do {
                try await env.store.write { db in
                    for id in ids {
                        if let count = report.uploadedByDestination[id], count > 0 {
                            try Self.noteUploads(db, id: id, count: count, now: now)
                        }
                    }
                    try BackfillCompletion.note(db, drained: report.drained, now: now, settings: settings)
                    if report.drained { try BackfillRunRepository.finishSettled(db, now: now) }
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

    static func uploadedText(_ count: Int) -> String {
        tr(vi: "Hôm nay đã upload \(L10n.integer(count)) file",
           en: L10n.plural(count, one: "1 file uploaded today", other: "\(L10n.integer(count)) files uploaded today"))
    }
}
