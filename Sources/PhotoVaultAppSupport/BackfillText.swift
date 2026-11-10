import Foundation
import PhotoVaultCore
import PhotoVaultEngine

/// Backfill is a one-time job. The menu bar shows it only while it runs; afterwards it is a record in
/// Settings, in Recent activity and in one notification.
public enum BackfillText {
    /// The backfill card is shown (see `PopoverJobVisibility`).
    public static func isRunning(_ snapshot: EngineSnapshot) -> Bool {
        PopoverJobVisibility.shows(backfill: snapshot)
    }

    /// The line under the Photos source in Settings › Nguồn; nil when there never was a backfill.
    public static func settingsLine(_ snapshot: EngineSnapshot, calendar: Calendar = .current) -> String? {
        if isRunning(snapshot) {
            let progress = "\(L10n.integer(snapshot.backfillDoneAssets)) / \(L10n.integer(snapshot.backfillTotalAssets))"
            return tr(vi: "Đang backfill: ", en: "Backfilling: ") + progress
        }
        guard let done = snapshot.backfillCompletion else { return nil }
        let when = done.completedAt.map { " " + tr(vi: "lúc ", en: "") + RelativeTimeText.dateTime($0, calendar: calendar) } ?? ""
        return tr(vi: "Backfill: xong", en: "Backfill: finished") + when + " · " + photos(done.assets)
    }

    public static func notification(_ done: BackfillCompletionSummary) -> (title: String, body: String) {
        (tr(vi: "Backfill xong", en: "Backfill finished"), done.countsText)
    }

    /// The end of a backfill whose notification has not been handled yet.
    public static func pendingNotification(_ snapshot: EngineSnapshot) -> BackfillCompletionSummary? {
        snapshot.backfillCompletion.flatMap { $0.notificationPending ? $0 : nil }
    }

    private static func photos(_ count: Int) -> String {
        let number = L10n.integer(count)
        return tr(vi: "\(number) ảnh", en: L10n.plural(count, one: "1 photo", other: "\(number) photos"))
    }
}
