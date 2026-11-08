import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// T30: sidecars per destination, uploaded only on change, never over foreign or modified files (FR-90..94).
@Suite struct SidecarTests {
    private func harness() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.placeNamesEnabled = false
        }
        return h
    }

    private func sidecars(_ destination: FakeDestination, suffix: String) async -> [FakeDestination.Item] {
        await destination.files.filter { $0.name.hasSuffix(suffix) }
    }

    private func sidecarJobs(_ h: Harness, _ destination: DestinationID) throws -> [UploadJob] {
        try h.jobs().filter { $0.destinationId == destination && $0.resType.isSidecar }
    }

    @Test func sidecarsAppearBesideTheOriginalOnceItsJobsFinished() async throws {
        let h = try await harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let names = await h.fileNames(h.drive)
        #expect(names.count == 3, "original, json, xmp: \(names)")
        let original = try #require(names.first { $0.hasSuffix(".HEIC") })
        let stem = String(original.dropLast(5))
        #expect(Set(names) == [original, stem + ".json", stem + ".xmp"])
        let paths = await h.backupPaths(h.drive)
        #expect(paths.count == 1)
        let sidecarPaths = await h.sidecarItems(h.drive)
        #expect(sidecarPaths.count == 2)
        #expect(Set(sidecarPaths.map(\.parentId)) == Set(await h.drive.files.map(\.parentId)), "all in one folder")
        let jobs = try sidecarJobs(h, .googleDrive)
        #expect(jobs.count == 2 && jobs.allSatisfy { $0.state == .done && $0.uploadedHash != nil })
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func sidecarContentDiffersPerDestinationAndMatchesTheBuilder() async throws {
        let h = try await harness()
        var driveRules = DestinationRules.everything
        driveRules.includeRaw = false
        try h.addDrive(scope: .full, rules: driveRules)
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("r", daysAgo: 3, raw: true, extra: [
            ResourceDescriptor(type: .alternatePhoto, uti: "public.jpeg", originalFilename: "DSC_r.JPG", isRaw: false),
        ]), recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let driveJson = try #require(await sidecars(h.drive, suffix: ".json").first)
        let nasJson = try #require(await sidecars(h.nas, suffix: ".json").first)
        #expect(driveJson.content?.sha256 != nasJson.content?.sha256, "each destination lists its own resources")
        // Both equal what the builder produces for that destination.
        for (destination, item) in [(DestinationID.googleDrive, driveJson), (h.nasId, nasJson)] {
            let key = AssetKey.local("r")
            let built = try h.read { db -> SidecarFile? in
                let asset = try #require(try AssetRepository.fetch(db, key: key))
                return try SidecarFactory.build(
                    db, asset: asset, destinationId: destination, type: .sidecarJson, settings: GlobalSettings(), timeZone: utc,
                    nameBuilder: NameStemBuilder(timeZone: utc, utiResolver: FakeUTIResolver()))
            }
            #expect(built?.sha256 == item.content?.sha256)
        }
        let drivePrimary = await h.backupPaths(h.drive)
        #expect(drivePrimary.count == 1 && drivePrimary[0].hasSuffix(".JPG"), "Drive keeps only the JPEG of the pair")
        #expect(await h.backupPaths(h.nas).count == 2)
        #expect(await sidecars(h.drive, suffix: ".xmp").count == 1, "one xmp per asset and destination")
    }

    @Test func destinationRulesDecideWhichSidecarsExist() async throws {
        let h = try await harness()
        var rules = DestinationRules.everything
        rules.sidecarXmp = false
        try h.addNAS(scope: .full, rules: rules)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(h.nasId)
        await h.settle()
        #expect(await sidecars(h.nas, suffix: ".json").count == 1)
        #expect(await sidecars(h.nas, suffix: ".xmp").isEmpty)
    }

    @Test func aFavoriteOnlyRefreshesTheSidecarsAndAnUnchangedOneIsNotUploadedAgain() async throws {
        let h = try await harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let before = await h.drive.files.map(\.id).sorted()
        let json = try #require(await sidecars(h.drive, suffix: ".json").first)
        let uploads = await h.drive.operationLog.filter { $0 == .upload }.count
        let replaces = await h.drive.operationLog.filter { $0 == .replace }.count

        // Same content again: nothing is uploaded.
        try await h.coordinator.refreshOrganization()
        await h.settle()
        #expect(await h.drive.operationLog.filter { $0 == .replace }.count == replaces)

        var favorite = h.snapshot("a", daysAgo: 3)
        favorite.isFavorite = true
        await h.fakePhotos.update(favorite)
        await h.settle()
        #expect(await h.drive.files.map(\.id).sorted() == before, "no new file")
        #expect(await h.drive.operationLog.filter { $0 == .upload }.count == uploads, "the original is not uploaded again")
        #expect(await h.drive.operationLog.filter { $0 == .replace }.count == replaces + 2, "json and xmp replaced in place")
        let updated = try #require(await sidecars(h.drive, suffix: ".json").first)
        #expect(updated.id == json.id && updated.content?.sha256 != json.content?.sha256)
        let jobs = try sidecarJobs(h, .googleDrive)
        #expect(jobs.allSatisfy { $0.state == .done && $0.doneGen == $0.targetGen && $0.targetGen == 2 })
    }

    @Test func aForeignSidecarIsNeverOverwritten() async throws {
        let h = try await harness()
        try await h.update { $0.sidecarJsonEnabled = false; $0.sidecarXmpEnabled = false }
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(h.nasId)
        await h.settle()
        try await h.update { $0.sidecarJsonEnabled = true; $0.sidecarXmpEnabled = true }
        try await h.coordinator.settingsChanged()
        // The NAS already has a file where the xmp goes (for example Lightroom's).
        await h.nas.failNext(.upload, with: .foreignFile)
        await h.settle()
        let jobs = try sidecarJobs(h, h.nasId)
        #expect(jobs.count == 2)
        #expect(jobs.filter { $0.state == .skipped && $0.stateReason == .foreignFile }.count == 1)
        #expect(jobs.filter { $0.state == .done }.count == 1)
    }

    @Test func aSidecarModifiedOutsideTheAppIsNotWrittenOver() async throws {
        let h = try await harness()
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(h.nasId)
        await h.settle()
        let xmp = try #require(await sidecars(h.nas, suffix: ".xmp").first)
        let foreign = try TestFiles.staged(Data("edited by Lightroom".utf8), in: h.root)
        await h.nas.externallyModify(xmp.id, content: foreign)

        var favorite = h.snapshot("a", daysAgo: 3)
        favorite.isFavorite = true
        await h.fakePhotos.update(favorite)
        await h.settle()
        let after = try #require(await sidecars(h.nas, suffix: ".xmp").first)
        #expect(after.content?.sha256 == foreign.sha256, "the owner's version stays")
        let job = try #require(try sidecarJobs(h, h.nasId).first { $0.resType == .sidecarXmp })
        #expect(job.state == .skipped && job.stateReason == .foreignModified)
    }

    @Test func albumChangesRegenerateTheSidecars() async throws {
        let h = try await harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let json = try #require(await sidecars(h.drive, suffix: ".json").first)
        await h.fakePhotos.setAlbums([AlbumSnapshot(localId: "alb", title: "Đà Lạt 2026", assetLocalIds: ["a"])])
        await h.settle()
        let updated = try #require(await sidecars(h.drive, suffix: ".json").first)
        #expect(updated.id == json.id && updated.content?.sha256 != json.content?.sha256)
    }

    @Test func assetsWithoutDoneOriginalsGetNoSidecar() async throws {
        let h = try await harness()
        try h.addDrive(scope: .full)
        await h.drive.setStatus(.unavailable(.offline))
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(try sidecarJobs(h, .googleDrive).isEmpty)
    }
}
