import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// FR-13 reconciliation, FR-53 cloud id backfill, T4b, T32 and the typed cycle failure.
@Suite struct ReconciliationTests {
    fileprivate func harness(scope: ScopeMode) async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: scope)
        return h
    }

    private func expireWithChange(_ h: Harness) async {
        // History older than a change that never reaches the engine: the stored token is useless.
        await h.add(h.snapshot("expiry-marker", daysAgo: 400), recordChange: true)
        await h.fakePhotos.expireHistory()
    }

    @Test(arguments: [ScopeMode.newOnly, .since(ArchiveDay(date: Date(timeIntervalSince1970: 1_793_000_000 - 20 * 86_400), timeZone: utc))])
    func t4bTokenExpiredWithFiftyNewPhotosUploadsAllOfThemAndAnUnhiddenPhotoIsNotNew(_ scope: ScopeMode) async throws {
        let h = try await harness(scope: scope)
        await h.add(h.snapshot("old", daysAgo: 90), recordChange: false)
        await h.add(h.snapshot("shy", daysAgo: 60, hidden: true), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(await h.drive.files.isEmpty)

        for index in 0..<50 { await h.add(h.snapshot("new\(index)", daysAgo: 1), recordChange: true) }
        await h.fakePhotos.update(h.snapshot("shy", daysAgo: 60, hidden: false))
        await h.fakePhotos.expireHistory()
        let before = try h.changeToken()
        let outcome = await h.run()
        guard case .completed(let report) = outcome else {
            Issue.record("expected a completed cycle, got \(outcome)")
            return
        }
        #expect(report.needsReconciliation == nil)
        #expect(try h.changeToken() != before, "a fresh token was saved")
        let names = await h.drive.files.map(\.name)
        #expect(names.count == 50, "all fifty new photos are backed up: \(names.count)")
        let shy = try #require(try h.asset(.local("shy")))
        #expect(!shy.isHidden && shy.insertedAt == nil, "an unhidden photo is not new")
        #expect(names.allSatisfy { !$0.contains("shy") })
        let old = try #require(try h.asset(.local("old")))
        #expect(old.insertedAt == nil)
        #expect(try h.asset(.local("new7"))?.insertedAt != nil)
    }

    @Test func reconciliationRecordsDeletionsHiddenFavoriteAndEditsAndRebuildsAlbums() async throws {
        let h = try await harness(scope: .newOnly)
        for id in ["keep", "gone", "edit", "fav"] { await h.add(h.snapshot(id, daysAgo: 30), recordChange: false) }
        await h.fakePhotos.setAlbums([AlbumSnapshot(localId: "al1", title: "Trip", assetLocalIds: ["keep", "gone"])])
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(try h.read { db in try AssetRepository.albums(db, for: .local("keep")).map(\.albumTitle) } == ["Trip"])

        await h.fakePhotos.delete(localId: "gone")
        var edited = h.snapshot("edit", daysAgo: 30)
        edited.modificationDate = h.clock.now
        await h.fakePhotos.update(edited)
        var favorite = h.snapshot("fav", daysAgo: 30)
        favorite.isFavorite = true
        await h.fakePhotos.update(favorite)
        await h.fakePhotos.setAlbums([AlbumSnapshot(localId: "al2", title: "Family", assetLocalIds: ["keep"])])
        await expireWithChange(h)
        await h.run()

        #expect(try h.asset(.local("gone"))?.deletedAt != nil, "gone from the library: only marked")
        #expect(try h.asset(.local("fav"))?.isFavorite == true)
        #expect(try h.asset(.local("keep"))?.deletedAt == nil)
        #expect(try h.read { db in try AssetRepository.albums(db, for: .local("keep")).map(\.albumTitle) } == ["Family"])
        #expect(await h.drive.files.count == 1, "only the new marker photo is uploaded, nothing old")
    }

    @Test func manualReconciliationFindsAPhotoThatNeverCameThroughChanges() async throws {
        let h = try await harness(scope: .newOnly)
        await h.add(h.snapshot("a", daysAgo: 30), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        await h.add(h.snapshot("sneaky", daysAgo: 1), recordChange: false)
        try await h.coordinator.runReconciliation()
        #expect(try h.asset(.local("sneaky"))?.insertedAt != nil)
        await h.run()
        #expect(await h.drive.files.count == 1)
    }

    @Test func reconciliationNeedsACompleteScan() async throws {
        let h = try await harness(scope: .full)
        await #expect(throws: EngineError.self) { try await h.coordinator.runReconciliation() }
    }

    // MARK: FR-53

    @Test func backfillAsksForCloudIdsInBatchesOfAtMostFiveHundred() async throws {
        let h = try await harness(scope: .newOnly)
        for index in 0..<1100 { await h.add(h.snapshot("bulk\(index)", daysAgo: 30), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.run()
        for index in 0..<1100 { await h.fakePhotos.add(h.snapshot("bulk\(index)", daysAgo: 30, cloud: "CLOUD-\(index)"), recordChange: false) }
        let recorded = try await h.coordinator.hardening.backfill.runAll(force: true)
        #expect(recorded == 1100)
        #expect(h.photos.cloudMappingBatches.filter { $0 > 0 }.allSatisfy { $0 <= 500 })
        let asset = try #require(try h.asset(.local("bulk3")))
        #expect(asset.cloudId == "CLOUD-3" && asset.assetKey == .local("bulk3"), "the key never changes")
        #expect(try h.aliases(of: asset.assetKey).contains("CLOUD-3"))
        #expect(try h.read { db in try AssetRepository.fetchMissingCloudId(db, limit: 10) }.isEmpty)
    }

    @Test func t32RebuiltLibraryReattachesByTheCloudIdLearnedByTheBackfill() async throws {
        let h = try await harness(scope: .full)
        await h.add(h.snapshot("A", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let files = await h.drive.files.map(\.id)
        #expect(files.count == 1)

        // Photos learns the cloud identifier later; the cycle's FR-53 step records it.
        await h.fakePhotos.add(h.snapshot("A", daysAgo: 2, cloud: "CLOUD-A"), recordChange: false)
        h.clock.advance(by: 2 * 3600)
        await h.run()
        #expect(try h.asset(.local("A"))?.cloudId == "CLOUD-A")

        // The library is rebuilt: new local identifiers, same cloud identifiers.
        await h.add(h.snapshot("marker", daysAgo: 400), recordChange: true)
        await h.fakePhotos.rebuildLibrary(renaming: ["A": "A-rebuilt"])
        await h.run()
        h.clock.advance(by: 60)
        await h.run()
        #expect(try h.assetCount() == 2, "re-attached, not a second copy")
        let asset = try #require(try h.asset(.local("A")))
        #expect(asset.localId == "A-rebuilt")
        #expect(try h.aliases(of: asset.assetKey).contains("A"))
        #expect(try h.jobs(.done).count == 2)
        #expect(await h.drive.files.map(\.id).filter { files.contains($0) } == files, "the same file, nothing uploaded for A again")
        #expect(await h.drive.files.count == 2, "A once, plus the marker photo")
    }

    // MARK: Typed failure

    @Test func aCycleThatFailsReportsTheErrorTypeInsteadOfSwallowingIt() async throws {
        let h = try await harness(scope: .full)
        await h.add(h.snapshot("a"), recordChange: false)
        try await h.baseline(.googleDrive)
        h.photos.failFetch = PhotosSourceError.networkError
        let outcome = await h.run()
        #expect(outcome == .failed(CycleFailure(source: .photos, errorType: "PhotosSourceError")))
        #expect(h.log.lines.allSatisfy { !$0.contains("networkError") }, "only the type is logged")
        h.photos.failFetch = nil
        guard case .completed = await h.run() else {
            Issue.record("the next cycle starts again")
            return
        }
    }
}

extension ReconciliationTests {
    @Test func aChangedModificationDateQueuesTheEditCheck() async throws {
        let h = try await harness(scope: .newOnly)
        await h.add(h.snapshot("e", daysAgo: 30), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        var edited = h.snapshot("e", daysAgo: 30)
        edited.modificationDate = h.clock.now
        await h.fakePhotos.add(edited, recordChange: false)
        try await h.coordinator.hardening.reconciler.reconcile(reason: .requested)
        #expect(try h.asset(.local("e"))?.editCheckPending == true)
    }
}
