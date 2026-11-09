import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct DeletedAssetAndClockTests {
    @Test func deletedLivePhotoCancelsRemainingJobsAndKeepsDoneOnes() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        var live = h.snapshot("live", subtypes: .photoLive)
        live.resources.append(ResourceDescriptor(type: .pairedVideo, uti: "com.apple.quicktime-movie", originalFilename: "IMG_live.MOV", isRaw: false))
        await h.add(live, recordChange: false)
        try await h.baseline(.googleDrive)
        h.photos.beforeExport = { _, type, _ in
            if type == .pairedVideo { throw PhotosSourceError.networkError }
        }
        await h.run()
        h.photos.beforeExport = nil
        await h.fakePhotos.delete(localId: "live")
        for _ in 0..<2 {
            h.clock.advance(by: 3 * 86_400)
            await h.run()
        }
        let states = Dictionary(uniqueKeysWithValues: try h.jobs().map { ($0.resType, $0.state) })
        #expect(states[.photo] == .done)
        #expect(states[.pairedVideo] == .cancelled)
        let snapshot = await h.coordinator.currentSnapshot()
        #expect(snapshot.pending == 0)
        #expect(snapshot.backfillDoneAssets == snapshot.backfillTotalAssets)
    }

    @Test func photoAddedAfterBackwardClockStepIsStillNewForNewOnly() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .newOnly)
        try await h.baseline(.googleDrive)
        await h.run()
        h.clock.advance(by: -120)
        await h.add(h.snapshot("fresh", daysAgo: 0))
        await h.run()
        await h.run()
        #expect(!(try h.jobs()).isEmpty)
        #expect(await h.drive.files.count > 0)
    }

    @Test func assetPresentAtBaselineStaysOutOfNewOnly() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .newOnly)
        await h.add(h.snapshot("old", daysAgo: 5), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(try h.jobs().isEmpty)
    }
}
