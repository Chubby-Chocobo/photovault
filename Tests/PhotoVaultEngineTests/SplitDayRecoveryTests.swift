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
    private let day = organizationDay
    private var daLatFolder: String { "\(day) Đà Lạt" }
    private var hanoiFolder: String { "\(day) Hà Nội" }

    /// Đà Lạt is the largest group, so its folder is the main one; "Hà Nội" sorts first by name.
    private struct World {
        var h: Harness
        var root: URL?
        var reader: DirectoryReader?
    }

    private func world(drive: Bool, local: Bool, localFirst: Bool = false, daLatCount: Int = 10, hanoiCount: Int = 3, raw: Bool = false) async throws -> World {
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
        if localFirst { try h.addNAS(scope: .full) }
        if drive { try h.addDrive(scope: .full) }
        if !localFirst, local { try h.addNAS(scope: .full) }
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        for index in 0..<daLatCount { await h.add(h.snapshot("d\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        for index in 0..<hanoiCount { await h.add(h.snapshot("h\(index)", daysAgo: 3, raw: raw, location: hanoi), recordChange: false) }
        try await h.coordinator.beginBaseline(destinations: drive ? [.googleDrive] + (local ? [h.nasId] : []) : [h.nasId])
        await h.settle(rounds: 8)
        return World(h: h, root: root, reader: reader)
    }

    private func listing(_ w: World) async -> [String] {
        var result: [String] = []
        for file in await w.h.drive.files { result.append("drive:" + (await w.h.drive.path(of: file.id))) }
        if let root = w.root { result += treeListing(root).keys.filter { !$0.hasPrefix(".photovault") }.map { "local:" + $0 } }
        return result.sorted()
    }

    private func folderRows(_ w: World) throws -> [String] {
        try w.h.read { db in
            try Row.fetchAll(db, sql: "SELECT destination_id, logical_path FROM remote_folder WHERE logical_path LIKE 'camera/%'")
                .map { ($0["destination_id"] as String) + "|" + ($0["logical_path"] as String) }
        }.sorted()
    }

    private func expectNothingMoved(_ w: World, listing before: [String], places: [String], movesBefore: Int = 0, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let h = w.h
        let after = await listing(w)
        #expect(after == before, "the listing is unchanged", sourceLocation: sourceLocation)
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

    private func recoverFresh(_ w: World, drive: Bool, local: Bool, localFirst: Bool = false) async throws {
        try await w.h.loseDatabase(localContent: w.reader)
        if localFirst {
            // The cycle recovers destinations in id order, so the second one is added once the first is done.
            try w.h.addNAS(scope: .full)
            try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId])
            await w.h.settle(rounds: 10)
            try w.h.addDrive(scope: .full)
            try await w.h.coordinator.beginBaseline(destinations: [.googleDrive])
            await w.h.settle(rounds: 10)
            return
        }
        if drive { try w.h.addDrive(scope: .full) }
        if local { try w.h.addNAS(scope: .full) }
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

    @Test func r3bLocalThenDriveWithALostDatabase() async throws {
        let w = try await world(drive: true, local: true, localFirst: true)
        let before = await listing(w)
        try await recoverFresh(w, drive: true, local: true, localFirst: true)
        try await expectNothingMoved(w, listing: before, places: ["Đà Lạt"])
    }

    // MARK: Intact database, owner-requested

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
        if driveFirst { try h.addDrive(scope: .full); try h.addNAS(scope: .full) } else { try h.addNAS(scope: .full); try h.addDrive(scope: .full) }
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
        let moves = try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE op = 'moveFile'") ?? 0 }
        #expect(moves == 0)
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
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full, rules: rules)
        try await h.coordinator.beginBaseline(destinations: [.googleDrive, h.nasId])
        await h.settle(rounds: 10)
        #expect(await listing(w) == before)
        #expect(try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job") ?? 0 } == 0)
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

    @Test func r9RestoringTheArchiveTimezoneClearsSlotsAndPlaceRows() async throws {
        let h = try await Harness.organized()
        try h.write { db in
            try DayPlaceRepository.save(db, DayPlace(day: self.day, slot: "pabcdef012345", placeKey: nil, placeName: "Hà Nội"))
            let asset = AssetRecord(assetKey: .local("x"), localId: "x", creationDate: h.clock.now, mediaType: .image, category: .camera, firstSeenAt: h.clock.now, lastSeenAt: h.clock.now)
            try AssetRepository.upsert(db, asset, timeZone: utc)
            try AssetPlacementRepository.setPlaceSlot(db, key: asset.assetKey, slot: "pabcdef012345")
        }
        try await RecoveryService.clearDayState(env: h.env)
        #expect(try h.read { db in try DayPlaceRepository.days(db) }.isEmpty)
        #expect(try h.asset(.local("x"))?.placeSlot == nil)
    }
}
