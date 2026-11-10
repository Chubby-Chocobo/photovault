import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A backfill is a one-time job: its end is recorded once (marker, activity row, notification flag).
@Suite struct BackfillCompletionTests {
    private func harness() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.sidecarJsonEnabled = false
            $0.sidecarXmpEnabled = false
        }
        try h.addDrive(scope: .full)
        return h
    }

    private func rows(_ h: Harness) throws -> [ActivityEvent] {
        try h.read { db in try ActivityRepository.recent(db) }.filter { $0.kind == .milestone && $0.message.hasPrefix(BackfillCompletion.activityPrefix) }
    }

    private func finishedBackfill(photos: Int = 3) async throws -> Harness {
        let h = try await harness()
        for index in 0..<photos { await h.add(h.snapshot("old\(index)", daysAgo: 5), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        return h
    }

    @Test func theEndOfABackfillIsRecordedOnceWithCountsAndSize() async throws {
        let h = try await finishedBackfill()
        let summary = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        #expect(summary.assets == 3)
        #expect(summary.bytes > 0)
        #expect(summary.notificationPending)
        #expect(summary.completedAt != nil)
        let recorded = try rows(h)
        #expect(recorded.count == 1)
        #expect(recorded.first?.message == BackfillCompletion.activityText(assets: 3, bytes: summary.bytes))
        let snapshot = await h.coordinator.currentSnapshot()
        #expect(snapshot.backfillDoneAssets == snapshot.backfillTotalAssets)
    }

    @Test func theTextCarriesCountsAndSizeOnly() {
        L10n.$override.withValue(.vi) {
            #expect(BackfillCompletion.activityText(assets: 1200, bytes: 3 * (1 << 30)) == "Backfill xong: 1.200 ảnh · 3,0 GB")
        }
        L10n.$override.withValue(.en) {
            #expect(BackfillCompletion.activityText(assets: 1, bytes: 1 << 20) == "Backfill finished: 1 photo · 1 MB")
            #expect(BackfillCompletion.activityText(assets: 2, bytes: 1 << 20) == "Backfill finished: 2 photos · 1 MB")
        }
    }

    @Test func nothingIsRecordedWhileBackfillJobsWait() async throws {
        let h = try await harness()
        let settings = await h.env.settingsSnapshot()
        await h.add(h.snapshot("old", daysAgo: 5), recordChange: false)
        try await h.baseline(.googleDrive)
        try h.write { db in try BackfillCompletion.note(db, drained: true, now: Date(), settings: settings) }
        #expect(try rows(h).isEmpty)
        #expect(await h.coordinator.currentSnapshot().backfillCompletion == nil)
    }

    @Test func aCycleThatIsNotDrainedRecordsNothing() async throws {
        let h = try await finishedBackfill()
        let settings = await h.env.settingsSnapshot()
        try h.write { db in
            try KeyValueRepository.set(db, BackfillCompletion.Key.completedMaxJob, nil)
            try db.execute(sql: "DELETE FROM activity")
            try BackfillCompletion.note(db, drained: false, now: Date(), settings: settings)
        }
        #expect(try rows(h).isEmpty)
    }

    @Test func acknowledgingClearsTheFlagAndARelaunchRepeatsNothing() async throws {
        let h = try await finishedBackfill()
        try await h.coordinator.acknowledgeBackfillNotification()
        var summary = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        #expect(!summary.notificationPending)
        let completedAt = summary.completedAt

        try await h.restart()
        try await h.coordinator.start()
        h.clock.advance(by: 3600)
        await h.settle()
        summary = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        #expect(!summary.notificationPending)
        #expect(summary.completedAt == completedAt)
        #expect(try rows(h).count == 1)
    }

    @Test func aRelaunchBeforeTheAcknowledgementKeepsTheFlag() async throws {
        let h = try await finishedBackfill()
        try await h.restart()
        try await h.coordinator.start()
        await h.settle()
        #expect(try #require(await h.coordinator.currentSnapshot().backfillCompletion).notificationPending)
        #expect(try rows(h).count == 1)
    }

    @Test func newPhotosAfterwardsAreNotABackfill() async throws {
        let h = try await finishedBackfill()
        try await h.coordinator.acknowledgeBackfillNotification()
        await h.add(h.snapshot("new", daysAgo: 0))
        await h.settle()
        #expect(try rows(h).count == 1)
        #expect(!(try #require(await h.coordinator.currentSnapshot().backfillCompletion).notificationPending))
    }

    @Test func aDestinationAddedLaterRunsAndRecordsAnotherBackfill() async throws {
        let h = try await finishedBackfill()
        try await h.coordinator.acknowledgeBackfillNotification()
        try h.addNAS(scope: .full)
        try await h.coordinator.destinationAdded(h.nasId)
        await h.settle()
        let summary = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        #expect(summary.notificationPending)
        #expect(summary.assets == 3)
        #expect(try rows(h).count == 2)
    }

    @Test func aBackfillFinishedBeforeTheUpgradeIsMarkedWithoutNoise() async throws {
        let h = try await finishedBackfill()
        let finishedAt = try h.read { db in try Date.fetchOne(db, sql: "SELECT MAX(updated_at) FROM upload_job WHERE state = 'done'") }
        try h.write { db in
            for key in [BackfillCompletion.Key.completedMaxJob, BackfillCompletion.Key.completedAt, BackfillCompletion.Key.completedAssets,
                        BackfillCompletion.Key.completedBytes, BackfillCompletion.Key.notifyPending] {
                try KeyValueRepository.set(db, key, nil)
            }
            try db.execute(sql: "DELETE FROM activity")
        }
        try await h.restart()
        try await h.coordinator.start()
        await h.settle()
        let summary = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        #expect(!summary.notificationPending)
        #expect(summary.assets == 3)
        #expect(summary.completedAt == finishedAt)
        #expect(try rows(h).isEmpty)
    }

    @Test func aLibraryWithoutAnyBackfillHasNoRecord() async throws {
        let h = try await harness()
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.coordinator.currentSnapshot().backfillCompletion == nil)
    }

    // MARK: Scope

    @Test func photosNoDestinationWillClassifyDoNotHoldTheEnd() async throws {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.sidecarJsonEnabled = false
            $0.sidecarXmpEnabled = false
        }
        try h.addDrive(scope: .since(ArchiveDay(date: h.clock.now.addingTimeInterval(-10 * 86_400), timeZone: utc)))
        for index in 0..<3 { await h.add(h.snapshot("in\(index)", daysAgo: 2), recordChange: false) }
        for index in 0..<1800 { await h.add(h.snapshot("out\(index)", daysAgo: 60), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        let provisional = try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE category_provisional = 1") ?? 0 }
        #expect(provisional >= 1800, "the old photos stay unclassified")
        let summary = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        #expect(summary.assets == 3)

        // The same state as an upgrade: no marker yet, the backfill long finished.
        try h.write { db in
            for key in [BackfillCompletion.Key.completedMaxJob, BackfillCompletion.Key.completedAt, BackfillCompletion.Key.completedAssets,
                        BackfillCompletion.Key.completedBytes, BackfillCompletion.Key.notifyPending] {
                try KeyValueRepository.set(db, key, nil)
            }
            try db.execute(sql: "DELETE FROM activity")
        }
        try await h.restart()
        try await h.coordinator.start()
        await h.settle()
        let marked = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        #expect(!marked.notificationPending)
        #expect(marked.assets == 3)
        #expect(try rows(h).isEmpty)
    }

    @Test func aPhotoADestinationStillNeedsClassifiedHoldsTheEnd() async throws {
        let h = try await finishedBackfill()
        let settings = await h.env.settingsSnapshot()
        try h.write { db in
            try KeyValueRepository.set(db, BackfillCompletion.Key.completedMaxJob, nil)
            try db.execute(sql: "DELETE FROM activity")
            try db.execute(sql: "UPDATE asset SET category_provisional = 1 WHERE asset_key = (SELECT MIN(asset_key) FROM asset)")
            try BackfillCompletion.note(db, drained: true, now: Date(), settings: settings)
        }
        #expect(try rows(h).isEmpty)
    }

    // MARK: Watermark

    @Test func aDestinationRemovedAndAddedAgainRunsAndRecordsAnotherBackfill() async throws {
        let h = try await finishedBackfill()
        try await h.coordinator.acknowledgeBackfillNotification()
        try h.addNAS(scope: .full)
        try await h.coordinator.destinationAdded(h.nasId)
        await h.settle()
        #expect(try rows(h).count == 2)

        try h.write { db in try DestinationRepository.remove(db, id: h.nasId) }
        await h.coordinator.destinationRemoved(h.nasId)
        try await h.coordinator.acknowledgeBackfillNotification()
        await h.env.destinations.add(h.nas)
        try h.addNAS(scope: .full)
        try await h.coordinator.destinationAdded(h.nasId)
        await h.settle()
        #expect(try rows(h).count == 3)
        #expect(try #require(await h.coordinator.currentSnapshot().backfillCompletion).notificationPending)
    }

    @Test func retryingSkippedFilesAfterTheEndAnnouncesNothingNew() async throws {
        let h = try await finishedBackfill()
        try await h.coordinator.acknowledgeBackfillNotification()
        try h.write { db in try db.execute(sql: "UPDATE upload_job SET state = 'skipped' WHERE id = (SELECT MAX(id) FROM upload_job)") }
        await h.settle()
        try h.write { db in try db.execute(sql: "UPDATE upload_job SET state = 'pending' WHERE state = 'skipped'") }
        await h.settle()
        #expect(try rows(h).count == 1)
        #expect(!(try #require(await h.coordinator.currentSnapshot().backfillCompletion).notificationPending))
    }

    @Test func aSecondEndCountsOnlyItsOwnPhotosAndBytes() async throws {
        let h = try await finishedBackfill()
        let first = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        try h.addNAS(scope: .full)
        try await h.coordinator.destinationAdded(h.nasId)
        await h.settle()
        let second = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        #expect(second.assets == 3)
        #expect(second.bytes == first.bytes, "the NAS copy, not Drive's bytes added again")
    }

    @Test func photosThatWereSkippedAreNotCounted() async throws {
        let h = try await finishedBackfill()
        let settings = await h.env.settingsSnapshot()
        try h.write { db in
            try KeyValueRepository.set(db, BackfillCompletion.Key.completedMaxJob, nil)
            try db.execute(sql: "UPDATE upload_job SET state = 'skipped' WHERE id = (SELECT MAX(id) FROM upload_job)")
            try BackfillCompletion.note(db, drained: true, now: Date(), settings: settings)
        }
        #expect(try #require(await h.coordinator.currentSnapshot().backfillCompletion).assets == 2)
    }

    // MARK: Paused and waiting destinations

    @Test func aDestinationPausedByTheOwnerDoesNotHoldTheBackfillOpen() async throws {
        let h = try await finishedBackfill()
        try await h.coordinator.acknowledgeBackfillNotification()
        try h.addNAS(scope: .full)
        try await h.coordinator.destinationAdded(h.nasId)
        let waiting = try h.read { db in try EngineQueries.backfillProgress(db) }
        #expect(waiting.done < waiting.total, "the NAS jobs wait")
        try h.write { db in try DestinationRepository.setStatus(db, id: h.nasId, status: .paused(.userPaused), now: h.clock.now) }
        let paused = try h.read { db in try EngineQueries.backfillProgress(db) }
        #expect(paused.done == paused.total)
        let snapshot = await h.coordinator.currentSnapshot()
        #expect(snapshot.backfillDoneAssets == snapshot.backfillTotalAssets, "the card hides")
    }

    @Test func aDestinationThatIsOfflineKeepsTheBackfillOpen() async throws {
        let h = try await finishedBackfill()
        try h.addNAS(scope: .full)
        try await h.coordinator.destinationAdded(h.nasId)
        try h.write { db in try DestinationRepository.setStatus(db, id: h.nasId, status: .unavailable(.offline), now: h.clock.now) }
        let progress = try h.read { db in try EngineQueries.backfillProgress(db) }
        #expect(progress.done < progress.total)
    }
}
