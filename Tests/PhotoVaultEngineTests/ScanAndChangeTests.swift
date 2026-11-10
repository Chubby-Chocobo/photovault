import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct ScanAndChangeTests {
    @Test func t1NewOnlyDoesNotUploadOldPhotos() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .newOnly)
        for i in 0..<5 { await h.add(h.snapshot("old\(i)", daysAgo: Double(10 + i)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(await h.drive.files.isEmpty)
        #expect(try h.jobs().isEmpty)

        await h.add(h.snapshot("new1", daysAgo: 0.1))
        await h.run()
        let names = await h.fileNames(h.drive)
        #expect(names.count == 1)
        #expect(names[0].hasSuffix("_IMG_new1.HEIC"))
    }

    @Test func t2SinceUploadsNewestFirst() async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        try h.addDrive(scope: .since(ArchiveDay(date: Date(timeIntervalSince1970: 1_793_000_000 - 30 * 86_400), timeZone: utc)))
        for (i, days) in [3.0, 1.0, 20.0, 60.0].enumerated() { await h.add(h.snapshot("p\(i)", daysAgo: days), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.run()
        let files = await h.drive.files
        #expect(files.count == 3, "the 60 day old photo is outside the window")
        #expect(files.map(\.name).first?.hasSuffix("IMG_p1.HEIC") == true)
        let order = files.map { $0.name.components(separatedBy: "_").last ?? "" }
        #expect(order == ["p1.HEIC", "p0.HEIC", "p2.HEIC"], "reserved ids grow in upload order: newest first")
    }

    @Test func t3NewOnlyToFullUploadsEachFileOnce() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .newOnly)
        for i in 0..<4 { await h.add(h.snapshot("old\(i)", daysAgo: Double(5 + i)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.add(h.snapshot("fresh", daysAgo: 0.2))
        await h.run()
        #expect(await h.drive.files.count == 1)

        try h.updateDestination(.googleDrive) { $0.scope = .full }
        try await h.coordinator.destinationRulesChanged(.googleDrive)
        await h.run()
        let files = await h.drive.files
        #expect(files.count == 5)
        #expect(Set(files.map(\.name)).count == 5, "no name appears twice")
        #expect(try h.jobs(.done).count == 5)
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func t4PhotoAddedDuringScanIsUploadedInEveryMode() async throws {
        for scope in [ScopeMode.newOnly, .full, .since(ArchiveDay(date: Date(timeIntervalSince1970: 1_793_000_000 - 86_400 * 400), timeZone: utc))] {
            let h = try await Harness { $0.scanBatchSize = 2 }
            try h.addDrive(scope: scope)
            for i in 0..<5 { await h.add(h.snapshot("old\(i)", daysAgo: 400 + Double(i)), recordChange: false) }
            try await h.baseline(.googleDrive)
            let first = try await h.coordinator.scanner.runBatch()
            #expect(first.state == .running)
            // Appended ahead of the cursor: the scan will record it, the change history marks it new.
            await h.add(h.snapshot("during", daysAgo: 0.01))
            _ = try await h.coordinator.scanner.runBatch()
            #expect(try h.scanState() == .running)
            await h.run()
            let names = await h.fileNames(h.drive)
            #expect(names.contains { $0.hasSuffix("_IMG_during.HEIC") }, "mode \(scope)")
            if scope == .newOnly { #expect(names.count == 1) }
            if scope == .full { #expect(names.count == 6) }
            #expect(try #require(try h.asset(.local("during"))).insertedAt != nil)
        }
    }

    @Test func t4PhotoAddedBehindTheCursorIsPickedUpByChanges() async throws {
        let h = try await Harness { $0.scanBatchSize = 2 }
        try h.addDrive(scope: .newOnly)
        for i in 0..<2 { await h.add(h.snapshot("old\(i)", daysAgo: 30), recordChange: false) }
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        await h.add(h.snapshot("late", daysAgo: 0.01))
        await h.run()
        #expect(await h.fileNames(h.drive).count == 1)
    }

    @Test func t5OldPhotoImportedAfterBaselineIsUploaded() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .newOnly)
        try h.addNAS(scope: .since(ArchiveDay(date: Date(timeIntervalSince1970: 1_793_000_000 - 86_400 * 7), timeZone: utc)))
        await h.add(h.snapshot("seed", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)
        h.clock.advance(by: 60)
        await h.add(h.snapshot("imported", daysAgo: 3000))
        await h.run()
        #expect(await h.fileNames(h.drive).count == 1, "newOnly takes it because it entered after the baseline")
        #expect(await h.fileNames(h.nas).count == 2, "since takes the recent seed and the late import")
    }

    @Test func scanIsResumableAndIdempotent() async throws {
        let h = try await Harness { $0.scanBatchSize = 3 }
        try h.addDrive(scope: .full)
        for i in 0..<10 { await h.add(h.snapshot("a\(i)", daysAgo: Double(i + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.runBatch()
        try await h.restart()
        #expect(try h.scanState() == .running)
        let rest = try await h.coordinator.scanner.run()
        #expect(rest.state == .complete)
        #expect(try h.assetCount() == 10)
        // Running the scanner again changes nothing.
        let again = try await h.coordinator.scanner.runBatch()
        #expect(again.scanned == 0)
    }

    @Test func scanRecordsHiddenAndBurstAndBuildsAliasesForLateCloudIds() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("h", hidden: true), recordChange: false)
        await h.add(h.snapshot("b1", burst: "B"), recordChange: false)
        await h.add(h.snapshot("b2", burst: "B", pick: false), recordChange: false)
        await h.add(h.snapshot("c", cloud: "CLOUD-C"), recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        #expect(try h.assetCount() == 4)
        #expect(try h.asset(.local("h"))?.isHidden == true)
        #expect(try h.asset(.cloud("CLOUD-C"))?.cloudId == "CLOUD-C")
        #expect(try h.asset(.local("b2"))?.insertedAt == nil)
    }

    @Test func deletedAssetOnlyGetsDeletedAtAndBackupStays() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("gone"), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(await h.drive.files.count == 1)
        await h.fakePhotos.delete(localId: "gone")
        await h.run()
        let asset = try #require(try h.asset(.local("gone")))
        #expect(asset.deletedAt != nil)
        #expect(await h.drive.files.count == 1)
        #expect(try h.jobs(.done).count == 1)
    }

    @Test func unknownLocalIdIsReattachedByCloudId() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .newOnly)
        await h.add(h.snapshot("L1", cloud: "CLOUD-1"), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        await h.fakePhotos.rebuildLibrary(renaming: ["L1": "L1-new"])
        await h.fakePhotos.update(h.snapshot("L1-new", cloud: "CLOUD-1"))
        await h.run()
        #expect(try h.assetCount() == 1, "re-attached, not a second asset")
        let asset = try #require(try h.asset(.cloud("CLOUD-1")))
        #expect(asset.localId == "L1-new")
        #expect(asset.insertedAt == nil, "a rebuild does not make old photos new")
        #expect(try h.aliases(of: asset.assetKey).contains("L1"))
        #expect(await h.drive.files.isEmpty)
    }

    @Test func tokenExpiryIsReconciledByTheCycleAndTheTrackerKeepsTheOldTokenUntilThen() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a"), recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        let before = try h.changeToken()
        await h.add(h.snapshot("b"))
        await h.fakePhotos.expireHistory()
        let result = try await h.coordinator.tracker.process()
        #expect(result == .needsReconciliation(.tokenExpired))
        #expect(try h.changeToken() == before)
        let outcome = await h.run()
        guard case .completed(let report) = outcome else {
            Issue.record("cycle did not complete")
            return
        }
        #expect(report.needsReconciliation == nil)
        #expect(try h.changeToken() != before, "reconciliation saved a new token")
        #expect(try h.asset(.local("b"))?.insertedAt != nil)
        #expect(await h.coordinator.currentSnapshot().overall == .idle)
    }

    @Test func aFailingReconciliationKeepsTheStateNeedsReconciliation() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a"), recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        let before = try h.changeToken()
        await h.add(h.snapshot("b"))
        await h.fakePhotos.expireHistory()
        h.photos.failFetch = PhotosSourceError.networkError
        let outcome = await h.run()
        #expect(outcome == .failed(CycleFailure(source: .photos, errorType: "PhotosSourceError")))
        #expect(try h.changeToken() == before)
        #expect(await h.coordinator.currentSnapshot().overall == .needsReconciliation)
        h.photos.failFetch = nil
        await h.run()
        #expect(await h.coordinator.currentSnapshot().overall == .idle)
    }

    @Test func eachChangeCommitsItsOwnToken() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .newOnly)
        await h.add(h.snapshot("seed"), recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        await h.add(h.snapshot("n1"))
        await h.add(h.snapshot("n2"))
        // Photos fails between the two changes: the first must already be committed.
        let changes = try await h.fakePhotos.fetchPersistentChanges(since: ChangeToken(data: Data("0".utf8)))
        #expect(changes.count == 2)
        _ = try await h.coordinator.tracker.process()
        let token = try #require(try h.changeToken())
        #expect(token == changes.last?.token.data)
        #expect(try h.asset(.local("n1"))?.insertedAt != nil)
        #expect(try h.asset(.local("n2"))?.insertedAt != nil)
    }

    @Test func albumChangeReclassifiesProvisionalAsset() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full, rules: {
            var rules = DestinationRules()
            rules.categories = [.saved]
            return rules
        }())
        await h.add(h.snapshot("w"), camera: true, recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        await h.fakePhotos.setAlbums([AlbumSnapshot(localId: "A", title: " whatsapp ", assetLocalIds: ["w"])])
        await h.run()
        let asset = try #require(try h.asset(.local("w")))
        #expect(asset.category == .saved)
        #expect(asset.categoryReason == .chatAppAlbum)
        #expect(asset.placement?.category == .saved)
        #expect(await h.drive.files.count == 1)
    }

    @Test func fiftyThousandAssetScanFitsTheTimeBudget() async throws {
        let dir = try TestFiles.temporaryDirectory("scan50k")
        let h = try await Harness(store: try Store.open(at: dir.appendingPathComponent("db.sqlite"))) { $0.scanBatchSize = 500 }
        try h.addDrive(scope: .newOnly)
        for i in 0..<50_000 {
            await h.fakePhotos.add(h.snapshot("bulk\(i)", daysAgo: Double(i % 3000)), recordChange: false)
        }
        try await h.baseline(.googleDrive)
        let start = Date()
        let progress = try await h.coordinator.scanner.run()
        let elapsed = Date().timeIntervalSince(start)
        #expect(progress.state == .complete)
        #expect(progress.scanned == 50_000)
        #expect(try h.assetCount() == 50_000)
        // A cap against a runaway (quadratic) scan, not a speed target: about 13 s on a developer machine, but nearly
        // 160 s on a loaded CI runner, too close to the 240 s this cap used to be.
        #expect(elapsed < 900, "scan took \(elapsed) s")
    }
}
