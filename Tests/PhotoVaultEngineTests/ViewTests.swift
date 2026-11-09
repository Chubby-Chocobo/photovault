import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// T35, T37, T38, T39: the shortcut views of Drive (FR-100..106, spec 8.13).
@Suite struct ViewTests {
    private let appleKey = DeviceNameResolver.key(make: "Apple", model: "iPhone 15")
    private let sonyKey = DeviceNameResolver.key(make: "SONY", model: "ILCE-7M4")
    private var appleGroup: String { DeviceNameResolver.groupId(forKey: appleKey) }
    private var sonyGroup: String { DeviceNameResolver.groupId(forKey: sonyKey) }

    private func harness() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.sidecarJsonEnabled = false
            $0.sidecarXmpEnabled = false
        }
        try h.addDrive(scope: .full)
        return h
    }

    /// Display paths of the live shortcuts, e.g. `By device/Apple iPhone 15/<day>/<name>`.
    private func shortcutPaths(_ h: Harness) async -> [String] {
        var paths: [String] = []
        let items = await h.drive.items
        for item in await h.drive.shortcuts where !item.trashed {
            // A shortcut inside a folder the owner trashed is gone for practical purposes.
            var ancestor = items[item.parentId]
            var hidden = false
            while let folder = ancestor {
                if folder.trashed { hidden = true }
                ancestor = items[folder.parentId]
            }
            if !hidden { paths.append(await h.drive.path(of: item.id)) }
        }
        return paths.sorted()
    }

    private func pathsUnder(_ prefix: String, _ h: Harness) async -> [String] {
        await shortcutPaths(h).filter { $0.hasPrefix(prefix) }
    }

    private func favorite(_ h: Harness, _ id: String, _ value: Bool, daysAgo: Double = 3) async {
        var snapshot = h.snapshot(id, daysAgo: daysAgo)
        snapshot.isFavorite = value
        await h.fakePhotos.update(snapshot)
    }

    @Test func t35ByDeviceShortcutsOpenTheRightFileAndFollowRenameAndMerge() async throws {
        let h = try await harness()
        try await h.update { $0.viewFavoritesEnabled = false; $0.viewByPlaceEnabled = false }
        await h.add(h.snapshot("a1", daysAgo: 3), recordChange: false)
        await h.add(h.snapshot("a2", daysAgo: 3), recordChange: false)
        await h.add(h.snapshot("sony1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()

        var paths = await shortcutPaths(h)
        #expect(paths.count == 3, "\(paths)")
        #expect(await pathsUnder("By device/Apple iPhone 15/\(organizationDay)/", h).count == 2)
        #expect(await pathsUnder("By device/Sony A7 IV/\(organizationDay)/", h).count == 1)
        // Every shortcut points at the original file of its asset.
        for shortcut in await h.drive.shortcuts {
            let target = try #require(await h.drive.items[shortcut.targetId ?? ""])
            #expect(target.kind == .file && target.appProperties[AppPropertyKey.resType] == "photo")
            #expect(shortcut.appProperties[AppPropertyKey.view] == "byDevice")
        }
        let viewFolder = try #require(await h.drive.folders.first { $0.name == "By device" })
        #expect(viewFolder.appProperties[AppPropertyKey.view] == "byDevice", "view folders carry pvView")

        // Rename: the folder changes name, the shortcuts stay where they are.
        let ids = await h.drive.shortcuts.map(\.id).sorted()
        try await h.coordinator.renameDeviceGroup(sonyGroup, to: "Máy ảnh của tôi")
        await h.settle()
        paths = await shortcutPaths(h)
        #expect(await pathsUnder("By device/Máy ảnh của tôi/\(organizationDay)/", h).count == 1)
        #expect(await h.drive.shortcuts.map(\.id).sorted() == ids, "no shortcut was created or removed")

        // A name that is taken is refused with a hint to merge.
        await #expect(throws: DeviceGroupError.duplicateName(existingGroupId: appleGroup)) {
            try await h.coordinator.renameDeviceGroup(self.sonyGroup, to: "apple iphone 15")
        }

        // Merge: the Sony shortcut moves into the Apple group.
        try await h.coordinator.mergeDeviceModel(sonyKey, into: appleGroup)
        await h.settle()
        #expect(await pathsUnder("By device/Apple iPhone 15/\(organizationDay)/", h).count == 3)
        #expect(await h.drive.shortcuts.filter { !$0.trashed }.count == 3)
        #expect(await h.drive.shortcuts.map(\.id).sorted() == ids, "moved, not recreated")
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func descriptionFollowsTheDeviceName() async throws {
        let h = try await harness()
        try await h.update { $0.viewFavoritesEnabled = false; $0.viewByPlaceEnabled = false }
        await h.add(h.snapshot("a1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let file = try #require(await h.backupFile(h.drive))
        #expect(file.description == "Camera: Apple iPhone 15 · Lens: Wide")
        try await h.coordinator.renameDeviceGroup(appleGroup, to: "iPhone của Ân")
        await h.settle()
        #expect(await h.backupFile(h.drive)?.description == "Camera: iPhone của Ân · Lens: Wide")
    }

    @Test func t37FavoritesCreateTrashAndRespectTheOwner() async throws {
        let h = try await harness()
        try await h.update { $0.viewByDeviceEnabled = false; $0.viewByPlaceEnabled = false }
        await h.add(h.snapshot("f1", daysAgo: 3), recordChange: false)
        await h.add(h.snapshot("f2", daysAgo: 4), recordChange: false)
        await h.add(h.snapshot("shot", daysAgo: 5, subtypes: .photoScreenshot), camera: false, recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await shortcutPaths(h).isEmpty)

        await favorite(h, "f1", true)
        await favorite(h, "shot", true, daysAgo: 5)
        await h.settle()
        let favorites = await shortcutPaths(h)
        #expect(favorites.count == 2, "favorites of every category: \(favorites)")
        #expect(await pathsUnder("Favorites/\(organizationDay)/", h).count == 1)
        #expect(favorites.allSatisfy { $0.hasPrefix("Favorites/20") }, "each favorite sits in its own day folder: \(favorites)")

        // Not a favorite any more: the shortcut is trashed, the file stays.
        await favorite(h, "f1", false)
        await h.settle()
        #expect(await shortcutPaths(h).count == 1)
        #expect(await h.drive.shortcuts.filter(\.trashed).count == 1)
        #expect(await h.backupPaths(h.drive).count == 3)

        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func aShortcutTheOwnerDeletedIsNotCreatedAgainUntilRebuild() async throws {
        let h = try await harness()
        try await h.update { $0.viewFavoritesEnabled = false; $0.viewByPlaceEnabled = false }
        await h.add(h.snapshot("a1", daysAgo: 3), recordChange: false)
        await h.add(h.snapshot("sony1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let sonyTarget = try #require(try h.jobs().first { $0.assetKey == .local("sony1") && $0.resType == .photo }?.remoteId)
        let shortcut = try #require(await h.drive.shortcuts.first { $0.targetId == sonyTarget })
        await h.drive.externallyDelete(shortcut.id)
        // The next touch of that shortcut finds it gone (404).
        try await h.coordinator.mergeDeviceModel(sonyKey, into: appleGroup)
        await h.settle()
        #expect(try h.shortcutRecords(.googleDrive, state: .userRemoved).count == 1)
        #expect(await h.drive.shortcuts.filter { $0.targetId == sonyTarget }.isEmpty, "not created again")
        await h.settle()
        #expect(await h.drive.shortcuts.filter { $0.targetId == sonyTarget }.isEmpty)

        try await h.coordinator.rebuildViews()
        await h.settle()
        #expect(await pathsUnder("By device/Apple iPhone 15/\(organizationDay)/", h).count == 2, "restored by Dựng lại view")
        #expect(try h.shortcutRecords(.googleDrive, state: .userRemoved).isEmpty)
    }

    @Test func t38ByPlaceGroupsByCountryAndProvinceAndIgnoresAssetsWithoutGps() async throws {
        let h = try await harness()
        try await h.update { $0.viewByDeviceEnabled = false; $0.viewFavoritesEnabled = false }
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(tokyo, en: tokyoEnglish, local: tokyoNative)
        await h.add(h.snapshot("vn", daysAgo: 3, location: daLat), recordChange: false)
        await h.add(h.snapshot("jp", daysAgo: 4, location: tokyo), recordChange: false)
        await h.add(h.snapshot("nogps", daysAgo: 5), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        var paths = await shortcutPaths(h)
        #expect(paths.count == 2, "\(paths)")
        #expect(await pathsUnder("By place/Vietnam/Lâm Đồng/\(organizationDay)/", h).count == 1, "\(paths)")
        #expect(await pathsUnder("By place/Japan/Tokyo (東京都)/", h).count == 1, "\(paths)")
        paths = await shortcutPaths(h)
        #expect(paths.allSatisfy { $0.split(separator: "/").count == 5 }, "country / area / day / file: \(paths)")
    }

    /// The backed-up file stays when a photo leaves Photos, so every view keeps pointing at it.
    @Test func aPhotoDeletedFromPhotosKeepsItsShortcutsInEveryView() async throws {
        let h = try await harness()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        var snapshot = h.snapshot("vn", daysAgo: 3, location: daLat)
        snapshot.isFavorite = true
        await h.add(snapshot, recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let before = await shortcutPaths(h)
        #expect(before.count == 3, "\(before)")

        await h.fakePhotos.delete(localId: snapshot.localId)
        _ = await h.run()
        await h.settle()
        #expect(await shortcutPaths(h) == before)
    }

    @Test func t39SwitchingViewsOffAndOnAndRebuildingAfterTheOwnerDeletedAFolder() async throws {
        let h = try await harness()
        try await h.update { $0.viewByDeviceEnabled = false; $0.viewByPlaceEnabled = false }
        await h.add(h.snapshot("f1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        await favorite(h, "f1", true)
        await h.settle()
        #expect(await shortcutPaths(h).count == 1)

        // Off keeps the tree; on again changes nothing.
        try await h.update { $0.viewFavoritesEnabled = false }
        try await h.coordinator.settingsChanged()
        await h.settle()
        #expect(await shortcutPaths(h).count == 1)
        try await h.update { $0.viewFavoritesEnabled = true }
        try await h.coordinator.settingsChanged()
        await h.settle()
        #expect(await h.drive.shortcuts.count == 1)

        // The owner trashes the whole view folder; a later favorite does not stop Drive.
        let favoritesFolder = try #require(await h.drive.folders.first { $0.appProperties[AppPropertyKey.logical] == "view/favorites" })
        await h.drive.externallyTrash(favoritesFolder.id)
        await h.add(h.snapshot("f2", daysAgo: 4))
        await favorite(h, "f2", true, daysAgo: 4)
        await h.settle()
        #expect(try h.shortcutRecords(.googleDrive, state: .userRemoved).count >= 1, "what was inside belongs to the owner now")
        #expect(try h.read { db in try DestinationRepository.fetch(db, id: .googleDrive)?.status } == .active, "Drive keeps running")
        #expect(await h.backupPaths(h.drive).count == 2, "uploads continued")

        // "Dựng lại view" brings the tree back, including what the owner removed.
        try await h.coordinator.rebuildViews()
        await h.settle()
        let rebuilt = await shortcutPaths(h)
        #expect(rebuilt.filter { $0.hasPrefix("Favorites/20") }.count == 2, "\(rebuilt)")
        #expect(try h.shortcutRecords(.googleDrive, state: .userRemoved).isEmpty)
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func driveRefusingShortcutsTurnsTheViewsOffWithoutRaisingScope() async throws {
        let h = try await harness()
        try await h.update { $0.viewByPlaceEnabled = false }
        await h.drive.setViewsPermitted(false)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.drive.shortcuts.isEmpty)
        #expect(try h.read { db in try ViewStage.isDisabled(db, .googleDrive) })
        let notices = try h.read { db in try ActivityRepository.recent(db).filter { $0.kind == .notice && $0.destinationId == .googleDrive } }
        #expect(notices.count == 1)
        #expect(await h.backupPaths(h.drive).count == 1, "backup is unaffected")
        let attempts = await h.drive.operationLog.filter { $0 == .shortcut }.count
        await h.settle()
        #expect(await h.drive.operationLog.filter { $0 == .shortcut }.count == attempts, "no more attempts")
    }

    @Test func aTargetThatChangesGetsANewShortcutAndTheOldOneIsTrashed() async throws {
        let h = try await harness()
        try await h.update { $0.viewByDeviceEnabled = false; $0.viewByPlaceEnabled = false }
        await h.add(h.snapshot("f1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        await favorite(h, "f1", true)
        await h.settle()
        let first = try #require(await h.drive.shortcuts.first)
        // The primary file was lost at Drive and uploaded again under a new id (integrity re-upload).
        try h.write { db in
            let job = try #require(try JobRepository.fetch(db, identity: JobIdentity(destinationId: .googleDrive, assetKey: .local("f1"), resType: .photo)))
            var changed = job
            changed.remoteId = "replacement"
            try JobRepository.save(db, &changed)
            try DirtyQueue.mark(db, asset: .local("f1"))
        }
        await h.settle()
        let shortcuts = await h.drive.shortcuts
        #expect(shortcuts.filter { !$0.trashed }.count == 1)
        #expect(shortcuts.first { $0.id == first.id }?.trashed == true)
    }
}

extension Harness {
    func backupFile(_ destination: FakeDestination) async -> FakeDestination.Item? {
        await destination.files.first { !$0.name.hasSuffix(".json") && !$0.name.hasSuffix(".xmp") }
    }
}
