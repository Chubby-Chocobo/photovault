import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A camera day with photos from several provinces gets one folder per province, at every destination.
@Suite struct SplitDayTests {
    private let day = organizationDay
    private var hanoiFolder: String { "\(day) Hà Nội" }
    private var daLatFolder: String { "\(day) Đà Lạt" }

    private func harness(sidecars: Bool = true, nas: Bool = true) async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.sidecarJsonEnabled = sidecars
            $0.sidecarXmpEnabled = sidecars
        }
        try h.addDrive(scope: .full)
        if nas { try h.addNAS(scope: .full) }
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        return h
    }

    /// 10 photos in Hà Nội and 3 in Đà Lạt, three days ago.
    private func addTrip(_ h: Harness, daysAgo: Double = 3) async {
        for index in 0..<10 { await h.add(h.snapshot("h\(index)", daysAgo: daysAgo, location: hanoi), recordChange: false) }
        for index in 0..<3 { await h.add(h.snapshot("d\(index)", daysAgo: daysAgo, location: daLat), recordChange: false) }
    }

    private func folderNames(_ destination: FakeDestination) async -> Set<String> {
        Set(await destination.folders.map(\.name).filter { $0.hasPrefix(day.description) })
    }

    private func paths(_ h: Harness, _ destination: FakeDestination, folder: String, sidecars: Bool = false) async -> [String] {
        var result: [String] = []
        for file in await destination.files where file.name.hasSuffix(".json") || file.name.hasSuffix(".xmp") ? sidecars : !sidecars {
            let path = await destination.path(of: file.id)
            if path.hasPrefix("Camera Uploads/\(folder)/") { result.append(path) }
        }
        return result
    }

    private func moveCount(_ h: Harness, _ operation: String? = nil) throws -> Int {
        try h.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE (? IS NULL OR op = ?)", arguments: [operation, operation]) ?? 0
        }
    }

    private func expectSettled(_ h: Harness, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for dest in [DestinationID.googleDrive, h.nasId] {
            for state in [MoveJobState.pending, .inProgress, .failed] {
                #expect(try h.moveJobs(state, destination: dest).isEmpty, "\(state) moves at \(dest)", sourceLocation: sourceLocation)
            }
        }
    }

    private func slots(_ h: Harness) throws -> [String: String?] {
        try h.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT local_id, place_slot FROM asset").map { ($0["local_id"] as String, $0["place_slot"] as String?) })
        }
    }

    @Test func twoProvincesGiveTwoFoldersAtEveryDestination() async throws {
        let h = try await harness()
        await addTrip(h)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        for destination in [h.drive, h.nas] {
            #expect(await folderNames(destination) == [hanoiFolder, daLatFolder])
            #expect(await paths(h, destination, folder: hanoiFolder).count == 10)
            #expect(await paths(h, destination, folder: daLatFolder).count == 3)
            #expect(await paths(h, destination, folder: hanoiFolder, sidecars: true).count == 20)
            #expect(await paths(h, destination, folder: daLatFolder, sidecars: true).count == 6)
        }
        let slotMap = try slots(h)
        #expect((0..<10).allSatisfy { slotMap["h\($0)"] == .some(nil) })
        let slot = try #require(slotMap["d0"] ?? nil)
        #expect(DynamicLayout.isValidSlot(slot))
        #expect((0..<3).allSatisfy { slotMap["d\($0)"] == slot })
        let rows = try h.read { db in try DayPlaceRepository.fetchAll(db, day: day) }
        #expect(rows.map(\.placeName) == ["Đà Lạt"] && rows.map(\.slot) == [slot])
        #expect(try h.dayStat(day)?.placeName == "Hà Nội")
        let logical = try h.read { db in try RemoteFolderRepository.fetch(db, destinationId: .googleDrive, logicalPath: "camera/\(day)@\(slot)") }
        #expect(logical?.displayName == daLatFolder)
        try expectSettled(h)
    }

    @Test func aSecondPassChangesNothing() async throws {
        let h = try await harness()
        await addTrip(h)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let moves = try moveCount(h)
        let before = try slots(h)
        await h.settle()
        #expect(try moveCount(h) == moves)
        #expect(try slots(h) == before)
    }

    @Test func aOneProvinceDayNeverMovesAFileOrWritesAPlaceRow() async throws {
        let h = try await harness()
        let near = GeoPoint(latitude: 11.9500, longitude: 108.4400)
        await h.geocoder.seed(near, en: daLatEnglish, local: daLatVietnamese)
        for index in 0..<6 { await h.add(h.snapshot("p\(index)", daysAgo: 3, location: index.isMultiple(of: 2) ? daLat : near), recordChange: false) }
        await h.add(h.snapshot("nogps", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        #expect(try moveCount(h, "moveFile") == 0)
        #expect(try h.read { db in try DayPlaceRepository.days(db) }.isEmpty)
        #expect(try slots(h).values.allSatisfy { $0 == nil })
        #expect(try h.dayStat(day)?.placeState == .named)
        #expect(await folderNames(h.drive) == [daLatFolder])
    }

    @Test func aDayUploadedBeforeItEndedSplitsAfterwardsAndMovesOnlyTheSmallGroup() async throws {
        let h = try await harness()
        await addTrip(h, daysAgo: 0.05)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let today = ArchiveDay(date: h.clock.now.addingTimeInterval(-0.05 * 86_400), timeZone: utc)
        #expect(try h.read { db in try DayPlaceRepository.exists(db, day: today) } == false)
        let hanoiIds = try h.jobs().filter { $0.assetKey.rawValue.contains("h") }.compactMap(\.remoteId)
        h.clock.advance(by: 2 * 86_400)
        await h.settle()
        #expect(try h.read { db in try DayPlaceRepository.exists(db, day: today) })
        let after = try h.jobs().filter { $0.assetKey.rawValue.contains("h") }.compactMap(\.remoteId)
        #expect(after.sorted() == hanoiIds.sorted())
        #expect(try moveCount(h, "moveFile") > 0)
        try expectSettled(h)
    }

    @Test func editingThePhotosBackIntoTheMainProvinceCollapsesTheGroup() async throws {
        let h = try await harness()
        await addTrip(h)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        for index in 0..<3 {
            var snapshot = try #require(try await h.fakePhotos.assets(localIds: ["d\(index)"]).first)
            snapshot.location = hanoi
            await h.fakePhotos.update(snapshot)
        }
        await h.settle(rounds: 6)
        #expect(await paths(h, h.drive, folder: hanoiFolder).count == 13)
        #expect(await paths(h, h.drive, folder: daLatFolder).isEmpty)
        #expect(await folderNames(h.drive).contains(daLatFolder), "the emptied folder stays")
        #expect(try slots(h).values.allSatisfy { $0 == nil })
        try expectSettled(h)
    }

    @Test func deletingTheSmallGroupMovesNothing() async throws {
        let h = try await harness()
        await addTrip(h)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let moves = try moveCount(h)
        for index in 0..<3 { await h.fakePhotos.delete(localId: "d\(index)") }
        await h.settle()
        #expect(try moveCount(h) == moves)
        #expect(await paths(h, h.drive, folder: daLatFolder).count == 3)
    }

    @Test func screenshotsAndSavedPhotosStayInTheirBranches() async throws {
        let h = try await harness()
        await addTrip(h)
        await h.add(h.snapshot("shot", daysAgo: 3, subtypes: .photoScreenshot, location: daLat), recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let all = await h.backupPaths(h.drive)
        #expect(all.filter { $0.hasPrefix("Screenshots/\(day)/") }.count == 1)
        #expect(all.filter { $0.hasPrefix("Camera Uploads/") }.count == 13)
        #expect(try slots(h)["shot"] == .some(nil))
    }

    @Test func aDestinationAddedAfterTheSplitCreatesBothFoldersWithoutMoves() async throws {
        let h = try await harness(nas: false)
        await addTrip(h)
        try await h.baseline(.googleDrive)
        await h.settle()
        let driveMoves = try moveCount(h, "moveFile")
        try h.addNAS(scope: .full)
        await h.env.destinations.add(h.nas)
        try await h.coordinator.destinationAdded(h.nasId)
        await h.settle()
        let nasFolders = await folderNames(h.nas)
        let nasPaths = await h.backupPaths(h.nas)
        #expect(nasFolders == [hanoiFolder, daLatFolder], "\(nasFolders) \(nasPaths)")
        #expect(try h.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE destination_id = ? AND op = 'moveFile'", arguments: [h.nasId.rawValue])
        } == 0)
        #expect(try moveCount(h, "moveFile") == driveMoves)
    }

    @Test func turningPlaceNamesOffAfterTheSplitQueuesNothing() async throws {
        let h = try await harness()
        await addTrip(h)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        try await h.update { $0.placeNamesEnabled = false }
        let moves = try moveCount(h)
        await h.add(h.snapshot("late", daysAgo: 3, location: daLat))
        var snapshot = try #require(try await h.fakePhotos.assets(localIds: ["h0"]).first)
        snapshot.location = daLat
        await h.fakePhotos.update(snapshot)
        await h.settle()
        #expect(try moveCount(h) == moves)
    }

    @Test func countryOnlyModeFreezesASplitDay() async throws {
        let h = try await harness()
        await addTrip(h)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let moves = try moveCount(h)
        let slotsBefore = try slots(h)
        try h.write { db in
            try KeyValueRepository.set(db, "place_country_only", 1)
            for day in try OrganizationQueries.promotedDays(db) { try DirtyQueue.mark(db, [.place], id: day.description) }
        }
        await h.settle()
        #expect(try moveCount(h) == moves)
        #expect(try slots(h) == slotsBefore)
        try h.write { db in
            try KeyValueRepository.set(db, "place_country_only", nil)
            for day in try OrganizationQueries.promotedDays(db) { try DirtyQueue.mark(db, [.place], id: day.description) }
        }
        await h.settle()
        #expect(try moveCount(h) == moves)
        #expect(try slots(h) == slotsBefore)
    }

    @Test func aDayNamedUnnamedBeforeTheUpgradeSplitsOnceItsBackfillRuns() async throws {
        let h = try await harness()
        try await h.update { $0.placeNamesEnabled = false }
        await addTrip(h)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        #expect(await folderNames(h.drive) == [day.description])
        try h.write { db in
            try db.execute(sql: "UPDATE day_stat SET place_state = 'unnamed'")
            try KeyValueRepository.set(db, "place_split_backfill", nil)
        }
        try await h.update { $0.placeNamesEnabled = true }
        await h.settle(rounds: 6)
        #expect(await folderNames(h.drive) == [hanoiFolder, daLatFolder])
        #expect(try h.read { db in try KeyValueRepository.int(db, "place_split_backfill") } == 1)
        let moves = try moveCount(h)
        await h.settle()
        #expect(try moveCount(h) == moves)
        try expectSettled(h)
    }

    @Test func aGroupWhoseNameIsStillOnDiskWaitsInItsFolderThenConverges() async throws {
        let h = try await harness()
        await addTrip(h)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let moves = try moveCount(h, "moveFile")
        let slotsBefore = try slots(h)
        let rowsBefore = try h.read { db in try DayPlaceRepository.fetchAll(db, day: self.day) }
        let snapshot = await h.env.settingsSnapshot()
        // Hà Nội is now called "Hanoi City" and its rename is queued; the Đà Lạt cell answers "Hà Nội",
        // which is still the first folder's name on disk until that rename has run.
        let outcome = try h.write { db -> DaySplitWriter.Outcome in
            let now = self.dayDate(h)
            for destination in [DestinationID.googleDrive, h.nasId] {
                try MoveJobRepository.insert(db, MoveJob(
                    destinationId: destination, operation: .renameFolder, subject: "camera/\(self.day)",
                    fromValue: self.hanoiFolder, toValue: "\(self.day) Hanoi City", createdAt: now))
            }
            try DayStatRepository.setPlace(db, day: self.day, state: .named, key: "VN|Hanoi", name: "Hanoi City")
            let renamed = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Hà Nội", locality: "Hanoi City")
            let reused = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Hà Nội")
            try GeoCacheRepository.save(db, GeoCacheEntry(cell: GeoCell(hanoi), locale: "local", place: renamed, fetchedAt: now))
            try GeoCacheRepository.save(db, GeoCacheEntry(cell: GeoCell(daLat), locale: "local", place: reused, fetchedAt: now))
            return try PlaceNamer.evaluateDay(db, day: self.day, context: try h.env.context(db, snapshot))
        }
        #expect(outcome.needsRetry)
        #expect(try slots(h) == slotsBefore)
        #expect(try h.read { db in try DayPlaceRepository.fetchAll(db, day: self.day) } == rowsBefore, "the waiting group keeps its folder and name")

        try h.write { db in try DirtyQueue.mark(db, [.place], id: self.day.description) }
        await h.settle(rounds: 6)
        #expect(await folderNames(h.drive) == ["\(day) Hanoi City", "\(day) Hà Nội"])
        #expect(await folderNames(h.nas) == ["\(day) Hanoi City", "\(day) Hà Nội"])
        #expect(await paths(h, h.drive, folder: "\(day) Hanoi City").count == 10)
        #expect(await paths(h, h.drive, folder: "\(day) Hà Nội").count == 3)
        #expect(try moveCount(h, "moveFile") == moves, "no file moved back and forth")
        #expect(try slots(h) == slotsBefore)
        try expectSettled(h)
    }

    private func dayDate(_ h: Harness) -> Date { h.clock.now }
}
