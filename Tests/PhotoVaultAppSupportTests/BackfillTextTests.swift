import Foundation
import PhotoVaultCore
@testable import PhotoVaultEngine
import Testing
@testable import PhotoVaultAppSupport

@Suite struct BackfillTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func snapshot(done: Int = 0, total: Int = 0, completion: BackfillCompletionSummary? = nil) -> EngineSnapshot {
        EngineSnapshot(
            overall: .idle, scanState: .complete, destinations: [], backfillDoneAssets: done, backfillTotalAssets: total,
            bytesUploaded: 0, etaSeconds: nil, pending: 0, deferred: 0, skipped: 0, missingRemote: 0, updatedAt: now,
            backfillCompletion: completion)
    }

    private func summary(at date: Date? = nil, assets: Int = 1200, bytes: Int64 = 3 * (1 << 30), pending: Bool = false) -> BackfillCompletionSummary {
        BackfillCompletionSummary(completedAt: date, assets: assets, bytes: bytes, notificationPending: pending)
    }

    @Test func theCardShowsOnlyWhileAssetsAreUnfinished() {
        #expect(!BackfillText.isRunning(snapshot()))
        #expect(BackfillText.isRunning(snapshot(done: 3, total: 10)))
        #expect(!BackfillText.isRunning(snapshot(done: 10, total: 10)))
    }

    @Test func settingsLineWhileRunning() {
        L10n.$override.withValue(.vi) {
            #expect(BackfillText.settingsLine(snapshot(done: 1200, total: 4800), calendar: utc) == "Đang backfill: 1.200 / 4.800")
        }
        L10n.$override.withValue(.en) {
            #expect(BackfillText.settingsLine(snapshot(done: 1200, total: 4800), calendar: utc) == "Backfilling: 1,200 / 4,800")
        }
    }

    @Test func settingsLineAfterwards() {
        let at = Date(timeIntervalSince1970: 1_799_000_000)
        L10n.$override.withValue(.vi) {
            #expect(BackfillText.settingsLine(snapshot(done: 5, total: 5, completion: summary(at: at)), calendar: utc) == "Backfill: xong lúc 03/01/2027 18:13 · 1.200 ảnh")
            #expect(BackfillText.settingsLine(snapshot(completion: summary()), calendar: utc) == "Backfill: xong · 1.200 ảnh")
        }
        L10n.$override.withValue(.en) {
            #expect(BackfillText.settingsLine(snapshot(completion: summary(at: at, assets: 1)), calendar: utc) == "Backfill: finished 3 Jan 2027 18:13 · 1 photo")
            #expect(BackfillText.settingsLine(snapshot(completion: summary(assets: 2)), calendar: utc) == "Backfill: finished · 2 photos")
        }
    }

    @Test func aNewBackfillShowsProgressNotTheOldRecord() {
        L10n.$override.withValue(.en) {
            #expect(BackfillText.settingsLine(snapshot(done: 1, total: 4, completion: summary(at: now)), calendar: utc) == "Backfilling: 1 / 4")
        }
    }

    @Test func noLineWithoutAnyBackfill() {
        #expect(BackfillText.settingsLine(snapshot(), calendar: utc) == nil)
    }

    @Test func notificationNamesCountsAndSizeOnly() {
        L10n.$override.withValue(.vi) {
            let text = BackfillText.notification(summary())
            #expect(text.title == "Backfill xong")
            #expect(text.body == "1.200 ảnh · 3,0 GB")
        }
        L10n.$override.withValue(.en) {
            let text = BackfillText.notification(summary(assets: 1, bytes: 5 << 20))
            #expect(text.title == "Backfill finished")
            #expect(text.body == "1 photo · 5 MB")
        }
    }

    @Test func onlyAPendingRecordIsToBeAnnounced() {
        #expect(BackfillText.pendingNotification(snapshot(completion: summary(pending: true)))?.assets == 1200)
        #expect(BackfillText.pendingNotification(snapshot(completion: summary(pending: false))) == nil)
        #expect(BackfillText.pendingNotification(snapshot()) == nil)
    }
}
