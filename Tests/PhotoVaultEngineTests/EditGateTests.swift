import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// T12, T13, T30b: the edit gate (FR-46).
@Suite struct EditGateTests {
    private let editedDescriptor = ResourceDescriptor(type: .fullSizePhoto, uti: "public.jpeg", originalFilename: "FullSizeRender.JPG", isRaw: false)

    private func harness() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.placeNamesEnabled = false
        }
        try h.addDrive(scope: .full)
        return h
    }

    private func editedSnapshot(_ h: Harness, _ id: String, adjusted: Bool = true, creation: Double = 3) -> AssetSnapshot {
        var snapshot = h.snapshot(id, daysAgo: creation, extra: [editedDescriptor])
        snapshot.hasAdjustments = adjusted
        snapshot.modificationDate = h.clock.now.addingTimeInterval(-5)
        return snapshot
    }

    private func edit(_ h: Harness, _ id: String, version: Int, hash: String? = nil, adjusted: Bool = true, creation: Double = 3) async {
        await h.fakePhotos.setAdjustmentHash(hash, for: id)
        await h.fakePhotos.update(editedSnapshot(h, id, adjusted: adjusted, creation: creation), resources: [.fullSizePhoto: Data("edit-\(version)".utf8)])
    }

    private func editedFiles(_ h: Harness) async -> [FakeDestination.Item] {
        await h.drive.files.filter { $0.name.contains("(edited)") }
    }

    private func hash(_ text: String) -> String { TestFiles.hashes(of: Data(text.utf8)).md5 }

    private func firstUpload(_ h: Harness) async throws {
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await editedFiles(h).isEmpty)
    }

    @Test func t12TheEditedFileLandsBesideTheOriginalEvenAfterTheDateChanged() async throws {
        let h = try await harness()
        try await firstUpload(h)
        // The owner fixes the date, then edits the photo.
        await edit(h, "a", version: 1, hash: "h1", creation: 10)
        await h.settle()
        let edited = try #require(await editedFiles(h).first)
        let original = try #require(await h.drive.files.first { $0.name.hasSuffix(".HEIC") })
        #expect(edited.parentId == original.parentId, "placement is fixed, so the edited file sits with the original")
        let sidecar = try #require(await h.sidecarItems(h.drive).first)
        #expect(sidecar.parentId == original.parentId)
        let json = try #require(await h.sidecarItems(h.drive).first { $0.name.hasSuffix(".json") })
        let editedJob = try #require(try h.jobs().first { $0.resType == .fullSizePhoto })
        #expect(editedJob.state == .done && editedJob.remoteId == edited.id)
        #expect(json.content != nil)
    }

    @Test func t13EditEditAgainFavoriteAndRevertKeepOneEditedFile() async throws {
        let h = try await harness()
        try await firstUpload(h)
        await edit(h, "a", version: 1, hash: "h1")
        await h.settle()
        let first = try #require(await editedFiles(h).first)
        let md5v1 = first.content?.md5

        await edit(h, "a", version: 2, hash: "h2")
        await h.settle()
        let files = await editedFiles(h)
        #expect(files.count == 1 && files[0].id == first.id, "replaced in place, same id")
        #expect(files[0].content?.md5 == hash("edit-2") && files[0].content?.md5 != md5v1)

        // Favorite: sidecars change, the edited file is untouched.
        let replacesBefore = await h.drive.operationLog.filter { $0 == .replace }.count
        var favorite = editedSnapshot(h, "a")
        favorite.isFavorite = true
        await h.fakePhotos.update(favorite)
        await h.settle()
        #expect(await h.drive.operationLog.filter { $0 == .replace }.count == replacesBefore + 2, "only json and xmp")
        #expect(await editedFiles(h).first?.content?.md5 == hash("edit-2"))

        // Revert in Photos: no adjustments any more, the edited file stays.
        let generation = try h.read { db in try ResourceRepository.fetch(db, key: .local("a"), type: .fullSizePhoto)?.contentGen }
        await edit(h, "a", version: 3, hash: nil, adjusted: false)
        await h.settle()
        let afterRevert = await editedFiles(h)
        #expect(afterRevert.count == 1 && afterRevert[0].content?.md5 == hash("edit-2"))
        #expect(try h.read { db in try ResourceRepository.fetch(db, key: .local("a"), type: .fullSizePhoto)?.contentGen } == generation)
    }

    /// The owner deleted the edited file at the destination, then edited the photo again: the replace
    /// cannot work, so the job waits for the owner's re-upload decision instead of retrying for 30 days.
    @Test func aNewEditOfAFileDeletedAtTheDestinationAsksTheOwner() async throws {
        let h = try await harness()
        try await firstUpload(h)
        await edit(h, "a", version: 1, hash: "h1")
        await h.settle()
        let edited = try #require(await editedFiles(h).first)
        await h.drive.externallyDelete(edited.id)
        await edit(h, "a", version: 2, hash: "h2")
        await h.settle()
        let missing = try h.jobs(.missingRemote)
        #expect(missing.count == 1 && missing.first?.resType == .fullSizePhoto)
        #expect(await h.coordinator.pendingOwnerDecisions().contains(.integrityMissing(.googleDrive, count: 1)))
        #expect(await editedFiles(h).isEmpty, "nothing is written until the owner confirms")
    }

    @Test func anAssetThatWasNeverAdjustedIsSkippedWithoutHashingOrExporting() async throws {
        let h = try await harness()
        try await firstUpload(h)
        var snapshot = h.snapshot("a", daysAgo: 3)
        snapshot.modificationDate = h.clock.now.addingTimeInterval(5)
        await h.fakePhotos.update(snapshot)
        await h.settle()
        #expect(try h.asset(.local("a"))?.editCheckPending == false)
        #expect(await h.fakePhotos.exports(of: "a") == 1)
    }

    @Test func anUnchangedAdjustmentHashDoesNotExportAgain() async throws {
        let h = try await harness()
        try await firstUpload(h)
        await edit(h, "a", version: 1, hash: "h1")
        await h.settle()
        let exports = await h.fakePhotos.exports(of: "a")
        // Photos touches the asset again (a favorite from another device) without a new edit.
        await edit(h, "a", version: 2, hash: "h1")
        await h.settle()
        #expect(await h.fakePhotos.exports(of: "a") == exports)
        #expect(await editedFiles(h).first?.content?.md5 == hash("edit-1"))
    }

    @Test func withoutAnAdjustmentHashTheModificationDateStandsIn() async throws {
        let h = try await harness()
        try await firstUpload(h)
        await edit(h, "a", version: 1, hash: nil)
        await h.settle()
        #expect(await editedFiles(h).first?.content?.md5 == hash("edit-1"))
        await edit(h, "a", version: 2, hash: nil)
        await h.settle()
        #expect(await editedFiles(h).count == 1)
        #expect(await editedFiles(h).first?.content?.md5 == hash("edit-2"), "a later modification re-exports")
        #expect(try h.asset(.local("a"))?.adjustmentHash?.hasPrefix("mod:") == true)
    }

    @Test func fallbackReExportsAreHeldBackWhenTheBackfillBucketIsEmpty() async throws {
        let h = try await harness()
        try await h.update { $0.backfillBytesPerHour = 1 << 20 }
        try await firstUpload(h)
        await edit(h, "a", version: 1, hash: nil)
        await h.settle()
        await edit(h, "a", version: 2, hash: nil)
        await h.settle()
        #expect(try h.asset(.local("a"))?.editCheckPending == true, "waiting for the bucket, not lost")
        // Time refills the bucket; the exports queued before the gate drain it first, so it takes a few refills.
        for _ in 0..<3 {
            h.clock.advance(by: 72 * 3600)
            await h.settle()
        }
        #expect(try h.asset(.local("a"))?.editCheckPending == false)
    }

    @Test func t30bTwoEditsWithinAMinuteWhileUploadingEndWithTheLastVersion() async throws {
        let h = try await harness()
        let wrapper = WrappedDestination(h.drive)
        await h.useWrapped(wrapper)
        try await firstUpload(h)
        await edit(h, "a", version: 1, hash: "h1")
        await h.settle()

        await edit(h, "a", version: 2, hash: "h2")
        // While the second version is being written the owner edits once more.
        let coordinator = h.coordinator
        let photos = h.fakePhotos
        let fired = Flag()
        wrapper.beforeReplace = { @Sendable in
            guard fired.takeFirst() else { return }
            var snapshot = self.editedSnapshot(h, "a")
            snapshot.modificationDate = h.clock.now.addingTimeInterval(30)
            await photos.setAdjustmentHash("h3", for: "a")
            await photos.update(snapshot, resources: [.fullSizePhoto: Data("edit-3".utf8)])
            _ = await coordinator.run(trigger: .photosChanged)
        }
        await h.settle()
        #expect(fired.isSet)
        let files = await editedFiles(h)
        #expect(files.count == 1)
        #expect(files[0].content?.md5 == hash("edit-3"), "the destination ends with the last version")
        let job = try #require(try h.jobs().first { $0.resType == .fullSizePhoto })
        #expect(job.state == .done && job.doneGen == job.targetGen)
    }

    @Test func t30bAnEditRaisedWhileTheJobIsUploadingIsNotLost() async throws {
        let h = try await harness()
        try await firstUpload(h)
        await edit(h, "a", version: 1, hash: "h1")
        await h.settle()
        await edit(h, "a", version: 2, hash: "h2")
        let raised = Flag()
        h.injector.onReach { point in
            guard point == .afterStartUpload, try h.jobs(.uploading).contains(where: { $0.resType == .fullSizePhoto }), raised.takeFirst() else { return }
            // What the gate does for a third edit while the second version is in flight.
            try h.write { db in
                let generation = try #require(try ResourceRepository.bumpContentGen(db, key: .local("a"), type: .fullSizePhoto))
                _ = try JobRepository.upsert(
                    db, desired: .init(identity: JobIdentity(destinationId: .googleDrive, assetKey: .local("a"), resType: .fullSizePhoto),
                                       origin: .refresh, targetGen: generation), now: h.clock.now)
            }
        }
        // The third version is already in Photos when the second one is exported.
        let latest = editedSnapshot(h, "a")
        await h.fakePhotos.add(latest, resources: [.fullSizePhoto: Data("edit-3".utf8)], recordChange: false)
        await h.settle()
        #expect(raised.isSet)
        #expect(await editedFiles(h).first?.content?.md5 == hash("edit-3"))
        let job = try #require(try h.jobs().first { $0.resType == .fullSizePhoto })
        #expect(job.state == .done && job.doneGen == job.targetGen)
    }

    @Test func sidecarsAreRegeneratedWhenTheEditedFileIsDone() async throws {
        let h = try await harness()
        try await firstUpload(h)
        let before = try #require(await h.sidecarItems(h.drive).first { $0.name.hasSuffix(".json") })
        await edit(h, "a", version: 1, hash: "h1")
        await h.settle()
        let after = try #require(await h.sidecarItems(h.drive).first { $0.name.hasSuffix(".json") })
        #expect(after.id == before.id && after.content?.sha256 != before.content?.sha256, "the JSON now lists the edited resource")
    }
}
