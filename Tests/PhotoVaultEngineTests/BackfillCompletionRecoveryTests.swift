import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Files that recovery matches after a database loss were not uploaded, so they are not a backfill.
@Suite struct BackfillCompletionRecoveryTests {
    private func lostDatabase(photos: Int = 3) async throws -> Harness {
        let h = try await Harness.organized()
        try await keepOnlyPhotos(h)
        try h.addDrive(scope: .full)
        for index in 0..<photos { await h.add(h.snapshot("old\(index)", daysAgo: 5), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        return h
    }

    /// The lost database held the settings too, so they are set again before the files are looked at.
    private func keepOnlyPhotos(_ h: Harness) async throws {
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.sidecarJsonEnabled = false
            $0.sidecarXmpEnabled = false
        }
    }

    private func recover(_ h: Harness) async throws {
        try await h.loseDatabase()
        try await keepOnlyPhotos(h)
        try h.addDrive(scope: .full)
        try await h.coordinator.beginBaseline(destinations: [.googleDrive])
        await h.settle(rounds: 10)
    }

    private func rows(_ h: Harness) throws -> [ActivityEvent] {
        try h.activity().filter { $0.kind == .milestone && $0.message.hasPrefix(BackfillCompletion.activityPrefix) }
    }

    @Test func filesRecoveryMatchesAreNotAnnouncedAsABackfill() async throws {
        let h = try await lostDatabase()
        try await recover(h)
        #expect(try rows(h).isEmpty)
        let summary = await h.coordinator.currentSnapshot().backfillCompletion
        #expect(summary == nil || !summary!.notificationPending)
        let marks = try h.read { db in try KeyValueRepository.string(db, BackfillCompletion.Key.completedMarks) }
        #expect(marks?.contains(DestinationID.googleDrive.rawValue) == true, "\(marks ?? "nil")")
    }

    @Test func aRecoveryThatAlsoUploadsMissingFilesCountsOnlyTheUploaded() async throws {
        let h = try await lostDatabase(photos: 4)
        let gone = try #require(await h.drive.files.first)
        await h.drive.externallyDelete(gone.id)
        try await recover(h)
        let summary = try #require(await h.coordinator.currentSnapshot().backfillCompletion)
        #expect(summary.assets == 1)
        let recorded = try rows(h)
        #expect(recorded.map(\.message) == [BackfillCompletion.activityText(assets: 1, bytes: summary.bytes)])
    }
}
