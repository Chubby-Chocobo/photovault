import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A split day comes back from the destinations with no file moved and no folder renamed, whatever
/// the destination, the order of recovery or the state of the database.
@Suite struct SplitDayRecoveryTests {
    let day = organizationDay
    var daLatFolder: String { "\(day) Đà Lạt" }
    var hanoiFolder: String { "\(day) Hà Nội" }

    /// Đà Lạt is the largest group, so its folder is the main one; "Hà Nội" sorts first by name.
    struct World {
        var h: Harness
        var root: URL?
        var reader: DirectoryReader?
    }

    func world(drive: Bool, local: Bool, localFirst: Bool = false, daLatCount: Int = 10, hanoiCount: Int = 3, raw: Bool = false) async throws -> World {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
        }
        var root: URL?
        var reader: DirectoryReader?
        if local {
            let real = try await h.useRealLocal()
            root = real.root
            reader = real.reader
        }
        try addDestinations(h, drive: drive, local: local, localFirst: localFirst)
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        for index in 0..<daLatCount { await h.add(h.snapshot("d\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        for index in 0..<hanoiCount { await h.add(h.snapshot("h\(index)", daysAgo: 3, raw: raw, location: hanoi), recordChange: false) }
        try await h.coordinator.beginBaseline(destinations: drive ? [.googleDrive] + (local ? [h.nasId] : []) : [h.nasId])
        await h.settle(rounds: 8)
        return World(h: h, root: root, reader: reader)
    }

    /// The destinations get distinct creation times, which is what orders them in the cycle.
    func addDestinations(_ h: Harness, drive: Bool, local: Bool, localFirst: Bool) throws {
        if localFirst, local { try h.addNAS(scope: .full); h.clock.advance(by: 1) }
        if drive { try h.addDrive(scope: .full); h.clock.advance(by: 1) }
        if !localFirst, local { try h.addNAS(scope: .full); h.clock.advance(by: 1) }
    }

    /// Drive files by id and path, so a move between two folders of the same name shows.
    func listing(_ w: World) async -> [String] {
        var result: [String] = []
        for file in await w.h.drive.files { result.append("drive:\(file.id):" + (await w.h.drive.path(of: file.id))) }
        if let root = w.root { result += treeListing(root).keys.filter { !$0.hasPrefix(".photovault") }.map { "local:" + $0 } }
        return result.sorted()
    }

    func expectUniqueDriveFolderNames(_ w: World, sourceLocation: SourceLocation = #_sourceLocation) async {
        let names = await w.h.drive.folders.filter { $0.id != "root" }.map { "\($0.parentId)/\($0.name)" }
        #expect(Set(names).count == names.count, "two Drive folders share a name: \(names)", sourceLocation: sourceLocation)
    }

    private func folderRows(_ w: World) throws -> [String] {
        try w.h.read { db in
            try Row.fetchAll(db, sql: "SELECT destination_id, logical_path FROM remote_folder WHERE logical_path LIKE 'camera/%'")
                .map { ($0["destination_id"] as String) + "|" + ($0["logical_path"] as String) }
        }.sorted()
    }

    func expectNothingMoved(_ w: World, listing before: [String], places: [String], movesBefore: Int = 0, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let h = w.h
        let after = await listing(w)
        #expect(after == before, "the listing is unchanged", sourceLocation: sourceLocation)
        await expectUniqueDriveFolderNames(w, sourceLocation: sourceLocation)
        let moves = try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job") ?? 0 }
        #expect(moves == movesBefore, "no move or rename was queued", sourceLocation: sourceLocation)
        let shared = try h.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (SELECT destination_id, remote_id FROM remote_folder WHERE remote_id IS NOT NULL
                    GROUP BY destination_id, remote_id HAVING COUNT(DISTINCT logical_path) > 1)
                """) ?? 0
        }
        #expect(shared == 0, "no two logical paths share a remote id", sourceLocation: sourceLocation)
        let names = try h.read { db in try DayPlaceRepository.fetchAll(db, day: self.day).compactMap(\.placeName) }
        #expect(names.sorted() == places.sorted(), "\(names)", sourceLocation: sourceLocation)
        #expect(try h.jobs().allSatisfy { $0.state == .done }, sourceLocation: sourceLocation)
    }

    func recoverFresh(_ w: World, drive: Bool, local: Bool, localFirst: Bool = false) async throws {
        try await w.h.loseDatabase(localContent: w.reader)
        try addDestinations(w.h, drive: drive, local: local, localFirst: localFirst)
        try await w.h.coordinator.beginBaseline(destinations: (drive ? [.googleDrive] : []) + (local ? [w.h.nasId] : []))
        await w.h.settle(rounds: 10)
    }

    // MARK: Lost database

    @Test func r1DriveWithALostDatabase() async throws {
        let w = try await world(drive: true, local: false)
        let before = await listing(w)
        #expect(before.contains { $0.contains(hanoiFolder) })
        try await recoverFresh(w, drive: true, local: false)
        try await expectNothingMoved(w, listing: before, places: ["Hà Nội"])
    }

    @Test func r2LocalWithALostDatabase() async throws {
        let w = try await world(drive: false, local: true)
        let before = await listing(w)
        try await recoverFresh(w, drive: false, local: true)
        // The main folder is not first by name, so the recovered slots differ from the lost ones; names match.
        try await expectNothingMoved(w, listing: before, places: ["Đà Lạt"])
    }

    @Test func r3DriveThenLocalWithALostDatabase() async throws {
        let w = try await world(drive: true, local: true)
        let before = await listing(w)
        try await recoverFresh(w, drive: true, local: true)
        try await expectNothingMoved(w, listing: before, places: ["Hà Nội"])
    }

    @Test func r3bALocalDestinationCreatedFirstStillWaitsForDrive() async throws {
        let w = try await world(drive: true, local: true, localFirst: true)
        let before = await listing(w)
        try await recoverFresh(w, drive: true, local: true, localFirst: true)
        try await expectNothingMoved(w, listing: before, places: ["Hà Nội"])
    }

    // MARK: Intact database, owner-requested

    /// Drive's `pvLogical` slots are the truth: the local bindings guessed by name order are rebound to them.
    private func expectLocalFollowsDrive(_ w: World, before: [String]) async throws {
        try await expectNothingMoved(w, listing: before, places: ["Hà Nội"])
        let h = w.h
        let main = "camera/\(day)"
        for id in [DestinationID.googleDrive, h.nasId] {
            let row = try #require(try h.read { db in try RemoteFolderRepository.fetch(db, destinationId: id, logicalPath: main) })
            #expect(row.displayName == daLatFolder, "\(id): the main folder is Đà Lạt")
        }
        let slot = try #require(try h.asset(.local("h0"))?.placeSlot)
        for id in [DestinationID.googleDrive, h.nasId] {
            let row = try #require(try h.read { db in try RemoteFolderRepository.fetch(db, destinationId: id, logicalPath: "camera/\(day)@\(slot)") })
            #expect(row.displayName == hanoiFolder, "\(id): the extra folder is Hà Nội")
        }
        #expect(try h.asset(.local("d0"))?.placeSlot == nil)
        #expect(try h.dayStat(day)?.placeName == "Đà Lạt")
        let drive = await w.h.drive.folders
        var driveNames: [String] = []
        for folder in drive where (await w.h.drive.path(of: folder.id)).hasPrefix("Camera Uploads/") { driveNames.append(folder.name) }
        let local = folderListing(w.root!).filter { $0.hasPrefix("Camera Uploads/") }.map { String($0.dropFirst("Camera Uploads/".count)) }
        #expect(driveNames.sorted() == local.sorted(), "both destinations carry the same folder names")
    }

    @Test func aDriveBackupAddedAfterTheNASWasRecoveredRebindsTheNASToDrivesSlots() async throws {
        let w = try await world(drive: true, local: true)
        let before = await listing(w)
        try await w.h.loseDatabase(localContent: w.reader)
        try w.h.addNAS(scope: .full)
        try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId])
        await w.h.settle(rounds: 10)
        // The NAS alone guessed its main folder (the first by name, Hà Nội); Drive's slots are the truth.
        try w.h.addDrive(scope: .full)
        try await w.h.coordinator.beginBaseline(destinations: [.googleDrive])
        await w.h.settle(rounds: 10)
        try await expectLocalFollowsDrive(w, before: before)
    }

    @Test func aDriveThatWasOfflineFromTheStartRebindsTheNASWhenItComesBack() async throws {
        let w = try await world(drive: true, local: true)
        let before = await listing(w)
        try await w.h.loseDatabase(localContent: w.reader)
        try w.h.addNAS(scope: .full)
        w.h.clock.advance(by: 1)
        try w.h.addDrive(scope: .full)
        await w.h.drive.setStatus(.unavailable(.offline))
        try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId, .googleDrive])
        await w.h.settle(rounds: 8)
        #expect(try w.h.destinationRecord(w.h.nasId).recoveryRequired == false, "the NAS recovered alone")
        await w.h.drive.setStatus(.active)
        await w.h.settle(rounds: 10)
        #expect(try w.h.destinationRecord(.googleDrive).recoveryRequired == false)
        try await expectLocalFollowsDrive(w, before: before)
    }

    @Test func r5OwnerRequestedRecoveryWithAnIntactDatabaseChangesNothing() async throws {
        let w = try await world(drive: true, local: true)
        let before = await listing(w)
        let rows = try folderRows(w)
        let movesBefore = try w.h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job") ?? 0 }
        let names = try w.h.read { db in try DayPlaceRepository.fetchAll(db, day: self.day).compactMap(\.placeName) }
        for id in [DestinationID.googleDrive, w.h.nasId] {
            _ = try await w.h.coordinator.startRecovery(id)
        }
        await w.h.settle(rounds: 6)
        try await expectNothingMoved(w, listing: before, places: names, movesBefore: movesBefore)
        #expect(try folderRows(w) == rows)
    }

    // MARK: Restored older backup

    @Test(arguments: [true, false])
    func r6AnOlderBackupFromBeforeTheSplitIsRecoveredWithoutMoves(driveFirst: Bool) async throws {
        let directory = try TestFiles.temporaryDirectory("db")
        let h = try await Harness.organized()
        let real = try await h.useRealLocal()
        let file = try Store.open(at: directory.appendingPathComponent("live.sqlite"))
        try await h.replaceStore(file, localContent: real.reader)
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.placeNamesEnabled = false
        }
        try addDestinations(h, drive: true, local: true, localFirst: !driveFirst)
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        for index in 0..<10 { await h.add(h.snapshot("d\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        for index in 0..<3 { await h.add(h.snapshot("h\(index)", daysAgo: 3, location: hanoi), recordChange: false) }
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle(rounds: 8)
        let backup = try DatabaseBackup(directory: directory.appendingPathComponent("backups")).backup(h.store, now: h.clock.now)

        try await h.update { $0.placeNamesEnabled = true }
        await h.settle(rounds: 8)
        let w = World(h: h, root: real.root, reader: real.reader)
        let before = await listing(w)
        #expect(before.contains { $0.contains(hanoiFolder) }, "the split happened after the backup")

        try await h.replaceStore(try Store.open(at: backup), localContent: real.reader)
        try h.write { db in
            for id in [DestinationID.googleDrive, h.nasId] { try DestinationRepository.setRecoveryRequired(db, id: id, true) }
        }
        await h.settle(rounds: 10)
        let after = await listing(w)
        #expect(after == before, "the listing is unchanged")
        let moves = try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job") ?? 0 }
        #expect(moves == 0, "no move or rename was queued")
        await expectUniqueDriveFolderNames(w)
        let shared = try h.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (SELECT destination_id, remote_id FROM remote_folder WHERE remote_id IS NOT NULL
                    GROUP BY destination_id, remote_id HAVING COUNT(DISTINCT logical_path) > 1)
                """) ?? 0
        }
        #expect(shared == 0)
    }

    // MARK: Destination that got only one group

    @Test func r7ADestinationThatNeverReceivedTheMainGroupIsRecoveredWithoutMoves() async throws {
        // Hà Nội is the largest group but its files are videos, which the NAS added afterwards leaves out.
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
        }
        let real = try await h.useRealLocal()
        try h.addDrive(scope: .full)
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        for index in 0..<10 { await h.add(h.snapshot("h\(index)", daysAgo: 3, type: .video, location: hanoi), recordChange: false) }
        for index in 0..<3 { await h.add(h.snapshot("d\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)
        var rules = DestinationRules.everything
        rules.includeVideos = false
        try h.addNAS(scope: .full, rules: rules)
        try await h.coordinator.destinationAdded(h.nasId)
        await h.settle(rounds: 8)
        let w = World(h: h, root: real.root, reader: real.reader)
        let before = await listing(w)
        let localFolders = folderListing(real.root).filter { $0.hasPrefix("Camera Uploads/") }
        #expect(localFolders == ["Camera Uploads/\(daLatFolder)"], "the NAS holds only the small group: \(localFolders)")

        try await h.loseDatabase(localContent: real.reader)
        try h.addNAS(scope: .full, rules: rules)
        h.clock.advance(by: 1)
        try h.addDrive(scope: .full)
        try await h.coordinator.beginBaseline(destinations: [h.nasId, .googleDrive])
        await h.settle(rounds: 10)
        #expect(await listing(w) == before)
        await expectUniqueDriveFolderNames(w)
        #expect(try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job") ?? 0 } == 0)
    }

    // MARK: Conflicting folders

    @Test func filesOfAFolderThatClaimsABoundPathAreNotAdoptedAndStayWhereTheyAre() async throws {
        let w = try await world(drive: true, local: false)
        let h = w.h
        let original = try #require(await h.drive.folders.first { $0.name == hanoiFolder })
        // A second Drive folder with the same name and logical path, holding one of the photos.
        let twin = FakeDestination.Item(
            id: "twin-folder", name: original.name, parentId: original.parentId, kind: .folder, appProperties: original.appProperties)
        await h.drive.put(twin)
        var movedFile = try #require(await h.drive.files.first { $0.parentId == original.id && $0.name.contains("IMG_h0.HEIC") })
        movedFile.parentId = twin.id
        await h.drive.put(movedFile)
        let before = await listing(w)
        let job = try #require(try h.jobs().first { $0.remoteId == movedFile.id })

        let outcome = try await h.coordinator.startRecovery(.googleDrive)
        guard case .recovered(let stats) = outcome else {
            Issue.record("expected a recovery, got \(outcome)")
            return
        }
        #expect(stats.folderConflicts == 1)
        #expect(stats.found - stats.matched >= 1, "the file in the dropped folder was left out of the recovery")
        #expect(await listing(w) == before, "nothing at the destination was touched")
        let after = try #require(try h.jobs().first { $0.assetKey == job.assetKey && $0.resType == job.resType })
        #expect(after.remoteId == job.remoteId && after.remoteLogicalParent == job.remoteLogicalParent, "its job is as it was")
        #expect(try h.activity().contains { $0.kind == .notice && $0.destinationId == .googleDrive && $0.message.contains("1") })
    }

    // MARK: Writer refusal

    @Test func r8AFolderWriteThatWouldShareARemoteIdIsRefusedAndCounted() async throws {
        let w = try await world(drive: false, local: true)
        let h = w.h
        let record = try h.destinationRecord(h.nasId)
        let main = try #require(try h.folderRows(h.nasId).first { $0.logicalPath == "camera/\(day)" })
        let writer = RecoveryWriter(env: h.env, record: record, timeZone: utc)
        let entry = RemoteFolderEntry(
            logicalPath: "camera/\(day)@pabcdef012345", remoteId: try #require(main.remoteId), displayName: daLatFolder,
            day: day, slot: "pabcdef012345", placeName: "Đà Lạt")
        let result = try await writer.writeFolders([entry], listedIds: [main.remoteId ?? ""])
        #expect(result.conflicts == 1)
        let rows = try h.folderRows(h.nasId).filter { $0.remoteId == main.remoteId }
        #expect(rows.count == 1)
    }

    // MARK: Timezone restore

    @Test func r9RestoringTheArchiveTimezoneThroughRecoveryClearsLeftoverSlotsAndPlaceRows() async throws {
        let w = try await world(drive: false, local: true)
        let h = w.h
        // The folder remembers another archive timezone than the fresh database that follows.
        let real = try #require(try await h.env.destinations.destination(for: h.nasId) as? LocalFolderDestination)
        try FileManager.default.removeItem(at: w.root!.appendingPathComponent(".photovault/destination.json"))
        _ = try await real.writeMarker(DestinationMarker(id: h.nasId, createdAt: h.clock.now, archiveTimezone: "Asia/Ho_Chi_Minh"))
        try await h.loseDatabase(localContent: w.reader)
        try h.addNAS(scope: .full)
        try h.write { db in
            try DayPlaceRepository.save(db, DayPlace(day: self.day, slot: "pleftover00000", placeKey: nil, placeName: "Leftover"))
        }
        try await h.coordinator.beginBaseline(destinations: [h.nasId])
        await h.settle(rounds: 8)
        #expect(await h.env.settings.snapshot().timeZone.identifier == "Asia/Ho_Chi_Minh", "the recovery restored the zone")
        let names = try h.read { db in try DayPlaceRepository.fetchAll(db, day: self.day).compactMap(\.placeName) }
        #expect(!names.contains("Leftover"), "\(names)")
    }

    @Test func aLocalDestinationWaitsWhileDriveIsOfflineThenRecovers() async throws {
        let w = try await world(drive: true, local: true)
        let before = await listing(w)
        try await w.h.loseDatabase(localContent: w.reader)
        try addDestinations(w.h, drive: true, local: true, localFirst: true)
        await w.h.drive.setStatus(.unavailable(.offline))
        try w.h.updateDestination(.googleDrive) { $0.recoveryRequired = true }
        try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId, .googleDrive])
        await w.h.settle(rounds: 4)
        #expect(try w.h.destinationRecord(w.h.nasId).recoveryRequired, "the NAS waits for Drive")
        #expect(try w.h.jobs().isEmpty, "nothing was recovered from the local tree yet")
        await w.h.drive.setStatus(.active)
        await w.h.settle(rounds: 10)
        #expect(try w.h.destinationRecord(w.h.nasId).recoveryRequired == false)
        try await expectNothingMoved(w, listing: before, places: ["Hà Nội"])
    }
}
