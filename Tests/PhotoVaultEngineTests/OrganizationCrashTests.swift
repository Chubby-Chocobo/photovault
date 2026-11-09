import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Process death in the middle of a move, a folder rename, a shortcut create and a sidecar replace:
/// the engine is rebuilt over the same database and destination and ends consistent, with no
/// duplicate files, folders or shortcuts.
@Suite struct OrganizationCrashTests {
    enum Target: String, CaseIterable, Sendable { case drive, nas }

    private func prepare(_ target: Target, views: Bool = false, sidecars: Bool = false) async throws -> (Harness, FakeDestination) {
        let h = try await Harness.organized { $0.maxConcurrentUploadsPerDestination = 1 }
        try await h.update {
            $0.sidecarJsonEnabled = sidecars
            $0.sidecarXmpEnabled = sidecars
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = views
        }
        switch target {
        case .drive: try h.addDrive(scope: .full)
        case .nas: try h.addNAS(scope: .full)
        }
        return (h, target == .drive ? h.drive : h.nas)
    }

    private func baseline(_ h: Harness, _ target: Target) async throws {
        switch target {
        case .drive: try await h.baseline(.googleDrive)
        case .nas: try await h.baseline(h.nasId)
        }
    }

    private func recover(_ h: Harness) async throws {
        try await h.restart()
        try await h.coordinator.start()
        await h.settle()
    }

    private func assertNoDuplicates(_ destination: FakeDestination, files: Int) async {
        let items = await destination.files
        #expect(items.count == files, "files: \(items.map(\.name))")
        #expect(Set(items.map(\.name)).count == items.count)
        #expect(await destination.contractViolations.isEmpty)
        let twins = Dictionary(grouping: await destination.folders.filter { $0.id != "root" }, by: { "\($0.parentId)/\($0.name)" })
        #expect(twins.values.allSatisfy { $0.count == 1 }, "no folder twice: \(twins.keys)")
    }

    @Test(arguments: Target.allCases)
    func crashWhileRenamingTheDayFolder(_ target: Target) async throws {
        let (h, destination) = try await prepare(target)
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.addCameraAssets(11, recordChange: false, location: daLat)
        try await h.update { $0.placeNamesEnabled = false }
        try await baseline(h, target)
        await h.settle()
        #expect(try h.dayStat(organizationDay)?.promoted == true)
        try await h.update { $0.placeNamesEnabled = true }
        await destination.crashAfterEffect(.rename)
        await h.run()
        #expect(try h.moveJobs(.inProgress, destination: destination.id).count == 1, "the crash left a rename in progress")

        try await recover(h)
        let expected = "\(organizationDay) Đà Lạt"
        #expect(await destination.folders.map(\.name).filter { $0.hasPrefix(organizationDay.description) } == [expected])
        let row = try h.read { db in try RemoteFolderRepository.fetch(db, destinationId: destination.id, logicalPath: "camera/\(organizationDay)") }
        #expect(row?.displayName == expected)
        #expect(try h.moveJobs(.inProgress, destination: destination.id).isEmpty && h.moveJobs(.pending, destination: destination.id).isEmpty)
        await assertNoDuplicates(destination, files: 11)
    }

    @Test func crashRightAfterTheShortcutWasCreatedDoesNotCreateItTwice() async throws {
        let (h, drive) = try await prepare(.drive, views: true)
        await h.add(h.snapshot("f1", daysAgo: 3), recordChange: false)
        try await baseline(h, .drive)
        await h.settle()
        var favorite = h.snapshot("f1", daysAgo: 3)
        favorite.isFavorite = true
        await h.fakePhotos.update(favorite)
        await drive.crashAfterEffect(.shortcut)
        await h.run()
        let pending = try h.shortcutRecords(.googleDrive, state: .pending)
        #expect(pending.count == 1 && pending[0].shortcutId != nil, "the reserved id was saved before the create")
        #expect(await drive.shortcuts.count == 1, "the crash happened after the effect")

        try await recover(h)
        #expect(await drive.shortcuts.count == 1, "no second shortcut")
        let records = try h.shortcutRecords(.googleDrive, state: .done)
        #expect(records.count == 1 && records[0].shortcutId == pending[0].shortcutId)
        #expect(await drive.contractViolations.isEmpty)
    }

    @Test func crashRightAfterTheShortcutFolderWasCreatedKeepsOneFolder() async throws {
        let (h, drive) = try await prepare(.drive, views: true)
        await h.add(h.snapshot("f1", daysAgo: 3), recordChange: false)
        try await baseline(h, .drive)
        await h.settle()
        var favorite = h.snapshot("f1", daysAgo: 3)
        favorite.isFavorite = true
        await h.fakePhotos.update(favorite)
        // Folder creation inside the view tree crashes after the effect once.
        h.injector.arm(.afterFolderCreated)
        await h.run()
        try await recover(h)
        #expect(await drive.shortcuts.count == 1)
        let twins = Dictionary(grouping: await drive.folders.filter { $0.id != "root" }, by: { "\($0.parentId)/\($0.name)" })
        #expect(twins.values.allSatisfy { $0.count == 1 })
    }

    @Test(arguments: Target.allCases)
    func crashAfterASidecarWasReplacedKeepsOneSidecarWithTheNewContent(_ target: Target) async throws {
        let (h, destination) = try await prepare(target, sidecars: true)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await baseline(h, target)
        await h.settle()
        let before = await h.sidecarItems(destination)
        #expect(before.count == 2)
        var favorite = h.snapshot("a", daysAgo: 3)
        favorite.isFavorite = true
        await h.fakePhotos.update(favorite)
        await destination.crashAfterEffect(.replace)
        await h.run()
        #expect(try h.jobs(.uploading).count == 1, "the crash left the sidecar job uploading")

        try await recover(h)
        await assertNoDuplicates(destination, files: 3)
        let after = await h.sidecarItems(destination)
        #expect(Set(after.map(\.id)) == Set(before.map(\.id)), "replaced in place")
        #expect(after.allSatisfy { item in before.first { $0.id == item.id }?.content?.sha256 != item.content?.sha256 })
        let jobs = try h.jobs().filter { $0.resType.isSidecar }
        #expect(jobs.count == 2 && jobs.allSatisfy { $0.state == .done }, "not skipped as foreignModified: \(jobs.map(\.state))")
        #expect(h.stagingFiles().isEmpty)
    }
}
