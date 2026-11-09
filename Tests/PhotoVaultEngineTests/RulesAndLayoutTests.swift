import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct RulesAndLayoutTests {
    private func rules(_ configure: (inout DestinationRules) -> Void) -> DestinationRules {
        var value = DestinationRules()
        configure(&value)
        return value
    }

    @Test func t6MixedLibraryUploadsEveryFrameAndNoHiddenAsset() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        let total = 1_000
        var expected = 0
        for i in 0..<total {
            let id = "m\(i)"
            switch i % 10 {
            case 0: await h.add(h.snapshot(id, hidden: true), recordChange: false)
            case 1: await h.add(h.snapshot(id, burst: "B\(i / 10)", pick: i % 20 != 1), recordChange: false); expected += 1
            case 2: await h.add(h.snapshot(id, type: .video), recordChange: false); expected += 1
            case 3: await h.add(h.snapshot(id, subtypes: .photoScreenshot), recordChange: false); expected += 1
            case 4: await h.add(h.snapshot(id, raw: true), recordChange: false); expected += 1
            default: await h.add(h.snapshot(id), recordChange: false); expected += 1
            }
        }
        try await h.baseline(.googleDrive)
        await h.run()
        let names = await h.fileNames(h.drive)
        #expect(names.count == expected)
        #expect(Set(names).count == names.count)
        #expect(!names.contains { $0.contains("IMG_m0.") || $0.contains("IMG_m10.") }, "hidden assets are not uploaded")
        #expect(try h.jobs().filter { $0.state != .done }.isEmpty)
        let hidden = try #require(try h.asset(.local("m0")))
        #expect(hidden.isHidden && hidden.deletedAt == nil, "hidden assets are recorded, only without jobs")
        #expect(try h.jobs().filter { $0.assetKey == .local("m0") }.isEmpty)
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func screenshotsAndSavedLandInTheirBranches() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("shot", subtypes: .photoScreenshot), recordChange: false)
        await h.add(h.snapshot("web"), camera: false, recordChange: false)
        await h.add(h.snapshot("cam"), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        let files = await h.drive.files
        var paths: [String] = []
        for file in files { paths.append(await h.drive.path(of: file.id)) }
        #expect(paths.contains { $0.hasPrefix("Screenshots/") && $0.hasSuffix("_IMG_shot.HEIC") })
        #expect(paths.contains { $0.hasPrefix("Saved/") && $0.hasSuffix("_IMG_web.HEIC") })
        #expect(paths.contains { $0.hasPrefix("Camera Uploads/20") && $0.hasSuffix("_IMG_cam.HEIC") })
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func t27ProvisionalCameraBecomesSavedAndReachesSavedOnlyDestination() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full, rules: rules { $0.categories = [.saved] })
        await h.add(h.snapshot("nocam"), camera: false, recordChange: false)
        await h.add(h.snapshot("cam"), camera: true, recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        let names = await h.fileNames(h.drive)
        #expect(names.count == 1, "only the saved photo; the camera photo has no destination")
        #expect(names[0].hasSuffix("_IMG_nocam.HEIC"))
        let nocam = try #require(try h.asset(.local("nocam")))
        #expect(nocam.category == .saved && !nocam.categoryProvisional)
        #expect(nocam.placement?.category == .saved)
        #expect(try h.jobs().count == 1)
    }

    @Test func classificationOnlyReadsAssetsSomeDestinationCouldNeed() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .newOnly)
        await h.add(h.snapshot("old"), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(await h.fakePhotos.headerReads.isEmpty, "out of scope for every destination, so no header download")
        await h.add(h.snapshot("new"))
        await h.run()
        #expect(await h.fakePhotos.headerReads == ["new"])
    }

    @Test func t27bRawJpegWhenDriveRejectsRaw() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full, rules: rules { $0.includeRaw = false })
        try h.addNAS(scope: .full)
        let raw = ResourceDescriptor(type: .photo, uti: "com.sony.arw-raw-image", originalFilename: "DSC_1.ARW", isRaw: true)
        let jpg = ResourceDescriptor(type: .alternatePhoto, uti: "public.jpeg", originalFilename: "DSC_1.JPG", isRaw: false)
        var snapshot = h.snapshot("pair")
        snapshot.resources = [raw, jpg]
        await h.add(snapshot, recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)
        await h.run()
        let driveNames = await h.fileNames(h.drive)
        #expect(driveNames.count == 1 && driveNames[0].hasSuffix(".JPG"), "Drive takes the JPEG only: \(driveNames)")
        let nasNames = await h.fileNames(h.nas)
        #expect(nasNames.count == 2)
        #expect(await h.fakePhotos.exports(of: "pair") == 2, "RAW and JPEG exported once each for both destinations")
        #expect(try h.jobs().allSatisfy { $0.state == .done })
    }

    @Test func t27bLivePhotoWithTwoConcurrentExportsDoesNotJam() async throws {
        let h = try await Harness { $0.maxConcurrentExports = 2 }
        try await h.update { $0.stagingSoftLimitBytes = 1 }
        try h.addDrive(scope: .full)
        var live = h.snapshot("live", subtypes: .photoLive)
        live.resources.append(ResourceDescriptor(type: .pairedVideo, uti: "com.apple.quicktime-movie", originalFilename: "IMG_live.MOV", isRaw: false))
        await h.add(live, recordChange: false)
        await h.add(h.snapshot("second"), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        let names = await h.fileNames(h.drive)
        #expect(names.count == 3, "photo, paired video and the second photo all arrive: \(names)")
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        #expect(h.stagingFiles().isEmpty)
    }

    @Test func t27cNasNewOnlyAddedAfterDriveIsFull() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        for i in 0..<3 { await h.add(h.snapshot("old\(i)", daysAgo: Double(3 + i)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(await h.drive.files.count == 3)

        h.clock.advance(by: 3600)
        try h.addNAS(scope: .newOnly)
        await h.env.destinations.add(h.nas)
        try await h.coordinator.destinationAdded(h.nasId)
        await h.run()
        #expect(await h.nas.files.isEmpty, "old photos never go to a newOnly destination added later")
        let exportsBefore = await h.fakePhotos.exports(of: "old0")

        h.clock.advance(by: 60)
        await h.add(h.snapshot("newer", daysAgo: 0))
        await h.run()
        #expect(await h.fileNames(h.nas).count == 1)
        #expect(await h.drive.files.count == 4)
        #expect(await h.fakePhotos.exports(of: "newer") == 1, "one export feeds both destinations (NFR-09)")
        #expect(await h.fakePhotos.exports(of: "old0") == exportsBefore)
    }

    @Test func narrowingCancelsAndWideningReinstatesFromTheDatabase() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", subtypes: .photoScreenshot), recordChange: false)
        await h.add(h.snapshot("v", type: .video), recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        try await h.update { $0.includeVideos = false }
        try await h.coordinator.settingsChanged()
        #expect(try h.jobs(.pending).count == 1)
        #expect(try h.jobs(.cancelled).count == 0, "the video never had a job while the switch was off")
        try await h.update { $0.includeVideos = true }
        try await h.coordinator.settingsChanged()
        #expect(try h.jobs(.pending).count == 2)
        try await h.update { $0.includeVideos = false }
        try await h.coordinator.settingsChanged()
        #expect(try h.jobs(.cancelled).count == 1)
        try await h.update { $0.includeVideos = true }
        try await h.coordinator.settingsChanged()
        #expect(try h.jobs(.pending).count == 2)
        let scans = await h.fakePhotos.exportCount
        #expect(scans.isEmpty, "no resource was touched while toggling")
    }

    @Test func hiddenAssetsDoNotCountTowardsTheDay() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        let created = h.clock.now.addingTimeInterval(-86_400)
        for i in 0..<3 {
            var s = h.snapshot("v\(i)")
            s.creationDate = created
            s.isHidden = i == 0
            await h.add(s, recordChange: false)
        }
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        await h.run()
        let day = ArchiveDay(date: created, timeZone: utc)
        let stat = try h.dayStat(day)
        #expect(stat?.count == 2)
        try await h.update { $0.includeHidden = true }
        try await h.coordinator.settingsChanged()
        await h.run()
        let hidden = try h.dayStat(day)
        #expect(hidden?.count == 3, "once hidden assets are in scope they are classified, placed and counted")
    }
}
