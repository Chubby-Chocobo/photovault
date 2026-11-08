import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// FR-51, spec 8.15 against a Drive-like destination: T31, T32 and the matching strategies.
@Suite struct RecoveryTests {
    private func layout(_ h: Harness) async -> [String] {
        await h.drive.items.values.filter { $0.id != "root" }.map { "\($0.id)|\($0.kind)|\($0.parentId)|\($0.name)|\($0.trashed)" }.sorted()
    }

    private func organizedLife() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update { $0.dayFolderThreshold = 3 }
        await h.geocoder.seed(daLat, en: daLatEnglish, vi: daLatVietnamese)
        try h.addDrive(scope: .full)
        await h.addCameraAssets(5, prefix: "d", daysAgo: 3, recordChange: false, location: daLat)
        var favorite = h.snapshot("fav", daysAgo: 40)
        favorite.isFavorite = true
        await h.add(favorite, recordChange: false)
        await h.add(h.snapshot("other", daysAgo: 40), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)
        return h
    }

    @Test func t31LostDatabaseIsRecoveredFromDriveWithoutUploadingAnythingAgain() async throws {
        let h = try await organizedLife()
        let day = organizationDay
        let promoted = try #require(try h.dayStat(day))
        #expect(promoted.promoted && promoted.placeName == "Đà Lạt", "the first life produced a named day folder: \(promoted)")
        let filesBefore = await h.drive.files.map(\.id).sorted()
        let originals = await h.drive.files.filter { $0.appProperties[AppPropertyKey.kind] == "original" }
        let layoutBefore = await layout(h)
        let shortcutCount = await h.drive.shortcuts.count
        #expect(filesBefore.count >= 14 && shortcutCount > 0)
        let operations = [FakeDestination.Operation.upload, .ensureFolder, .move, .rename, .shortcut, .replace]
        var counts: [FakeDestination.Operation: Int] = [:]
        for op in operations { counts[op] = await h.count(of: op, on: h.drive) }
        let placements = try h.placements()
        let allocations = try h.nameAllocations()
        let folders = try h.folderRows(.googleDrive).map { "\($0.logicalPath)|\($0.remoteId ?? "-")|\($0.displayName)" }
        let doneBefore = try h.jobs(.done).count
        let shortcutsBefore = try h.shortcutRows(.googleDrive).map { "\($0.view)|\($0.assetKey)|\($0.shortcutId ?? "-")" }.sorted()

        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)

        #expect(await h.drive.files.map(\.id).sorted() == filesBefore, "no file was uploaded again")
        #expect(await layout(h) == layoutBefore, "files, folders and shortcuts are exactly where they were")
        for original in originals {
            #expect(await h.drive.items[original.id]?.content == original.content, "an original is never rewritten")
        }
        for op in operations where op != .replace {
            #expect(await h.count(of: op, on: h.drive) == counts[op], "no \(op) call after the recovery")
        }
        #expect(await h.drive.contractViolations.isEmpty)
        #expect(try h.placements() == placements, "placement and names come back from the file names")
        #expect(try h.nameAllocations() == allocations)
        #expect(try h.folderRows(.googleDrive).map { "\($0.logicalPath)|\($0.remoteId ?? "-")|\($0.displayName)" } == folders)
        #expect(try h.jobs(.done).count == doneBefore)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        #expect(try h.shortcutRows(.googleDrive).map { "\($0.view)|\($0.assetKey)|\($0.shortcutId ?? "-")" }.sorted() == shortcutsBefore)
        let stat = try #require(try h.dayStat(day))
        #expect(stat.promoted && stat.placeName == "Đà Lạt", "the promoted day and its place come from the folder, not from the default threshold")
        let record = try h.destinationRecord(.googleDrive)
        #expect(record.status == .active && !record.recoveryRequired)
        #expect(try h.activity().contains { $0.kind == .recovered })
    }

    @Test func nothingIsUploadedWhileTheDestinationIsRecovering() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        try h.updateDestination(.googleDrive) { $0.recoveryRequired = true }
        // The scan is not done in the first call of the cycle; recovery waits for it, uploads wait for recovery.
        h.photos.failFetch = PhotosSourceError.networkError
        await h.run()
        h.photos.failFetch = nil
        #expect(await h.drive.files.isEmpty)
        await h.run()
        #expect(try h.destinationRecord(.googleDrive).recoveryRequired == false)
        #expect(await h.drive.files.count == 1, "uploads start once recovery found nothing to recover")
    }

    @Test func recoveryNeedsACompleteScan() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        let outcome = try await h.coordinator.startRecovery(.googleDrive)
        #expect(outcome == .notReady(.scanIncomplete))
    }

    // MARK: Strategies

    @Test func longKeysAreMatchedThroughTheHashedPropertyValue() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        let cloud = String(repeating: "Z", count: 130)
        await h.add(h.snapshot("long", daysAgo: 2, cloud: cloud), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let file = try #require(await h.drive.files.first)
        let claimed = try #require(file.appProperties[AppPropertyKey.assetId])
        #expect(claimed.hasPrefix("h:"), "the key was too long for an app property: \(claimed.prefix(8))")

        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.drive.files.map(\.id) == [file.id], "matched by the hash index, not uploaded again")
        #expect(try h.jobs(.done).count == 1)
    }

    @Test func aKeyThatDiffersFromTheAssetKeyIsMatchedByIdentifierAndRecordedAsAlias() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("A", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let file = try #require(await h.drive.files.first)
        #expect(file.appProperties[AppPropertyKey.assetId] == "l:A")

        // After the loss the library reports a cloud identifier: the asset is now keyed `c:`.
        await h.fakePhotos.add(h.snapshot("A", daysAgo: 2, cloud: "CLOUD-A"), recordChange: false)
        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle()
        let asset = try #require(try h.asset(.cloud("CLOUD-A")))
        #expect(try h.aliases(of: asset.assetKey).contains("A"), "the old identifier is kept as an alias")
        #expect(await h.drive.files.map(\.id) == [file.id])
        #expect(try h.jobs(.done).map(\.assetKey) == [.cloud("CLOUD-A")])
    }

    @Test func fingerprintMatchingUsesTheArchiveTimezoneOfTheRoot() async throws {
        let h = try await Harness()
        let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        try await h.env.settings.setArchiveTimeZone(saigon)
        try h.addDrive(scope: .full)
        // 18:30 UTC is 01:30 the next day in Ho Chi Minh City: the names depend on the zone.
        for id in ["x1", "x2"] {
            var snapshot = h.snapshot(id, daysAgo: 2)
            snapshot.creationDate = Date(timeIntervalSince1970: 1_792_000_000 + (id == "x1" ? 0 : 600))
            await h.add(snapshot, recordChange: false)
        }
        try await h.baseline(.googleDrive)
        await h.settle()
        let files = await h.drive.files
        #expect(files.count == 2)
        // The root remembers the zone; the files lose their keys (an older version of the app).
        await h.drive.rewriteProperties(of: "root") { _ in AppPropertyCodec.rootProperties(archiveTimezone: saigon) }
        for file in files { await h.drive.rewriteProperties(of: file.id) { $0.filter { $0.key != AppPropertyKey.assetId } } }

        try await h.loseDatabase()
        #expect(await h.env.settings.snapshot().timeZone.identifier == utc.identifier, "the new database starts with the Mac's zone")
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.env.settings.snapshot().timeZone.identifier == saigon.identifier, "restored from pvArchiveTZ before fingerprinting")
        #expect(await h.drive.files.map(\.id).sorted() == files.map(\.id).sorted(), "matched by creation time and file name, not uploaded again")
        #expect(try h.jobs(.done).count == 2)
        let names = try h.placements().values.sorted()
        #expect(names.allSatisfy { $0.contains("camera|2026-10-") }, "\(names)")
    }

    @Test func lookAlikeFilesAreToldApartByTheirContentWhenTheNamesAreTheSame() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        let when = Date(timeIntervalSince1970: 1_792_000_000)
        for id in ["twinA", "twinB"] {
            var snapshot = h.snapshot(id, daysAgo: 2)
            snapshot.creationDate = when
            snapshot.resources = [ResourceDescriptor(type: .photo, uti: "public.heic", originalFilename: "IMG_0001.HEIC", isRaw: false)]
            await h.add(snapshot, recordChange: false)
        }
        try await h.baseline(.googleDrive)
        await h.settle()
        let files = await h.drive.files
        #expect(files.count == 2)
        let exportsBefore = await h.fakePhotos.exports(of: "twinA") + h.fakePhotos.exports(of: "twinB")
        let owners = try h.read { db in
            Dictionary(uniqueKeysWithValues: try JobRepository.fetch(db, state: .done).map { ($0.remoteId ?? "", $0.assetKey) })
        }
        for file in files { await h.drive.rewriteProperties(of: file.id) { $0.filter { $0.key != AppPropertyKey.assetId } } }

        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.drive.files.count == 2, "nothing was uploaded again")
        let after = try h.read { db in
            Dictionary(uniqueKeysWithValues: try JobRepository.fetch(db, state: .done).map { ($0.remoteId ?? "", $0.assetKey) })
        }
        #expect(after == owners, "each file is tied to the asset whose bytes it holds")
        let exportsAfter = await h.fakePhotos.exports(of: "twinA") + h.fakePhotos.exports(of: "twinB")
        #expect(exportsAfter > exportsBefore, "the look-alikes were compared by content")
    }

    @Test func filesNoAssetMatchesAreLeftAloneAndNeverTouched() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("mine", daysAgo: 2), recordChange: false)
        await h.add(h.snapshot("deleted", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let before = await h.drive.files.map(\.id).sorted()
        await h.fakePhotos.delete(localId: "deleted")

        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.drive.files.map(\.id).sorted() == before, "the backup of a deleted photo stays")
        #expect(try h.jobs(.done).count == 1)
        #expect(await h.drive.items.values.allSatisfy { !$0.trashed })
    }
}

/// A recovery the cycle already did is not repeated by a command that waited behind it.
@Suite struct RecoveryRepeatTests {
    @Test func aRecoveryRequestedBeforeAnotherRecoveryFinishedDoesNothingWhenItsTurnComes() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        try await h.coordinator.scanner.run()
        try h.updateDestination(.googleDrive) { $0.recoveryRequired = true }
        let coordinator = h.coordinator

        // The owner's request is made while the destination still needs recovery, then waits for the lane.
        await coordinator.lane.beginCommand()
        let request = Task { try await coordinator.startRecovery(.googleDrive) }
        var waiting = false
        for _ in 0..<2_000 where !waiting {
            waiting = await coordinator.lane.hasWaitingCommands
            if !waiting { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        #expect(waiting)
        // Meanwhile the cycle's own recovery finishes.
        let first = try await coordinator.hardening.recovery.recover(.googleDrive)
        guard case .recovered = first else {
            Issue.record("expected the first recovery to finish, got \(first)")
            return
        }
        let lists = await h.count(of: .list, on: h.drive)
        let activities = try h.activity().filter { $0.kind == .recovered }.count
        await coordinator.lane.endCommand()

        #expect(try await request.value == .recovered(RecoveryStats()))
        #expect(await h.count(of: .list, on: h.drive) == lists, "the root was not listed again")
        #expect(try h.activity().filter { $0.kind == .recovered }.count == activities)
        #expect(try h.destinationRecord(.googleDrive).status == .active)
    }

    @Test func anOwnerRequestForADestinationThatNeverNeededRecoveryStillRuns() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        try await h.coordinator.scanner.run()
        let before = await h.count(of: .list, on: h.drive)
        _ = try await h.coordinator.startRecovery(.googleDrive)
        #expect(await h.count(of: .list, on: h.drive) > before)
    }
}
