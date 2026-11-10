import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Split days under imports, missing geocodes, setting changes and pending renames.
@Suite struct SplitDayScenarioTests {
    private let day = organizationDay
    private var hanoiFolder: String { "\(day) Hà Nội" }
    private var daLatFolder: String { "\(day) Đà Lạt" }

    private func harness(hanoiCount: Int = 10, daLatCount: Int = 3, seed: Bool = true, nas: Bool = true) async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
        }
        try h.addDrive(scope: .full)
        if nas { try h.addNAS(scope: .full) }
        if seed {
            await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
            await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        }
        for index in 0..<hanoiCount { await h.add(h.snapshot("h\(index)", daysAgo: 3, location: hanoi), recordChange: false) }
        for index in 0..<daLatCount { await h.add(h.snapshot("d\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        return h
    }

    private func folderNames(_ destination: FakeDestination) async -> Set<String> {
        Set(await destination.folders.map(\.name).filter { $0.hasPrefix(day.description) })
    }

    private func count(_ destination: FakeDestination, in folder: String) async -> Int {
        var n = 0
        for file in await destination.files where !file.name.hasSuffix(".json") && !file.name.hasSuffix(".xmp") {
            if await destination.path(of: file.id).hasPrefix("Camera Uploads/\(folder)/") { n += 1 }
        }
        return n
    }

    private func moveFiles(_ h: Harness) throws -> Int {
        try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE op = 'moveFile'") ?? 0 }
    }

    private func renames(_ h: Harness) throws -> Int {
        try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE op = 'renameFolder'") ?? 0 }
    }

    private func slots(_ h: Harness) throws -> [String: String?] {
        try h.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT local_id, place_slot FROM asset").map { ($0["local_id"] as String, $0["place_slot"] as String?) })
        }
    }

    private func unsettled(_ h: Harness) throws -> Int {
        try [DestinationID.googleDrive, h.nasId].reduce(0) { total, id in
            try total + [MoveJobState.pending, .inProgress, .failed].reduce(0) { $0 + (try h.moveJobs($1, destination: id).count) }
        }
    }

    // MARK: Import

    @Test func anImportIntoASplitDayFollowsTheSameRule() async throws {
        let h = try await harness()
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let moves = try moveFiles(h)
        let hanoiIds = try h.jobs().filter { $0.assetKey.rawValue.contains("h") }.compactMap(\.remoteId)

        let folder = try ImportFolder()
        let date = h.clock.now.addingTimeInterval(-3 * 86_400)
        try folder.add("a.jpg", metadata: ImportFolder.photo(at: date.addingTimeInterval(60), location: daLat))
        try folder.add("b.jpg", metadata: ImportFolder.photo(at: date.addingTimeInterval(120), location: daLat))
        try await h.startImport(folder, settle: 8)

        #expect(try moveFiles(h) == moves, "imported files land in their folder without a move")
        #expect(try h.jobs().filter { $0.assetKey.rawValue.contains("h") }.compactMap(\.remoteId) == hanoiIds)
        #expect(await count(h.drive, in: daLatFolder) == 5)
        #expect(await count(h.drive, in: hanoiFolder) == 10)
        #expect(try unsettled(h) == 0)
    }

    // MARK: Missing geocode

    @Test func aDayWaitsWhileOneProvincesGeocodeIsMissingThenSplits() async throws {
        let h = try await harness(seed: false)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.hold(GeoCell(daLat))
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let waiting = try h.dayStat(day)
        let cache = try h.read { db in try Row.fetchAll(db, sql: "SELECT * FROM geo_cache").map { "\($0)" } }
        let requestCount = await h.geocoder.requests.count
        #expect(waiting?.placeState == .waitingGeocode, "\(String(describing: waiting)) requests=\(requestCount) \(cache)")
        #expect(try moveFiles(h) == 0)
        #expect(try h.read { db in try DayPlaceRepository.exists(db, day: self.day) } == false)
        #expect(try slots(h).values.allSatisfy { $0 == nil })

        await h.geocoder.release(GeoCell(daLat))
        h.clock.advance(by: 31 * 60)
        await h.settle(rounds: 6)
        #expect(await folderNames(h.drive) == [hanoiFolder, daLatFolder])
        #expect(await count(h.drive, in: daLatFolder) == 3)
        #expect(try unsettled(h) == 0)
    }

    // MARK: Groups

    @Test func twoUnnamedGroupsShareOneFolder() async throws {
        // Each province's photos span more than 300 km, so both groups are unnamed.
        let h = try await harness(hanoiCount: 0, daLatCount: 0)
        let points: [(String, GeoPoint, String)] = [
            ("n1", GeoPoint(latitude: 22.3, longitude: 103.8), "Lao Cai"), ("n2", GeoPoint(latitude: 22.3, longitude: 107.2), "Lao Cai"),
            ("s1", GeoPoint(latitude: 9.2, longitude: 105.1), "Ca Mau"), ("s2", GeoPoint(latitude: 9.2, longitude: 108.5), "Ca Mau"),
        ]
        for (id, point, province) in points {
            let english = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: province, locality: nil)
            await h.geocoder.seed(point, en: english, local: english)
            await h.add(h.snapshot(id, daysAgo: 3, location: point), recordChange: false)
        }
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        #expect(try h.dayStat(day)?.placeState == .unnamed)
        #expect(try h.read { db in try DayPlaceRepository.exists(db, day: self.day) } == false)
        #expect(await folderNames(h.drive) == [day.description])
        #expect(try moveFiles(h) == 0)
    }

    @Test func twoGroupsThatSwapNamesMoveEachFileOnceAndStayStable() async throws {
        let h = try await harness()
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let before = try moveFiles(h)
        // Hà Nội's cell now answers "Đà Lạt" and Đà Lạt's cell answers "Hà Nội".
        try h.write { db in
            let asHanoi = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Hà Nội", locality: "Đà Lạt")
            let asDaLat = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Hà Nội")
            try GeoCacheRepository.save(db, GeoCacheEntry(cell: GeoCell(hanoi), locale: "local", place: asHanoi, fetchedAt: h.clock.now))
            try GeoCacheRepository.save(db, GeoCacheEntry(cell: GeoCell(daLat), locale: "local", place: asDaLat, fetchedAt: h.clock.now))
            try DirtyQueue.mark(db, [.place], id: self.day.description)
        }
        await h.settle(rounds: 8)
        #expect(await folderNames(h.drive) == [hanoiFolder, daLatFolder])
        #expect(await count(h.drive, in: hanoiFolder) == 3, "the folders swapped contents")
        #expect(await count(h.drive, in: daLatFolder) == 10)
        let afterFirst = try moveFiles(h)
        let slotsAfter = try slots(h)
        let tooMany = try h.read { db in
            try Row.fetchAll(db, sql: "SELECT subject, destination_id, COUNT(*) AS n FROM move_job WHERE op = 'moveFile' GROUP BY subject, destination_id HAVING n > 2")
        }
        #expect(tooMany.isEmpty, "no file moved more than once after the split itself")
        try h.write { db in try DirtyQueue.mark(db, [.place], id: self.day.description) }
        await h.settle(rounds: 4)
        #expect(try moveFiles(h) == afterFirst && afterFirst > before)
        #expect(try slots(h) == slotsAfter)
        #expect(try unsettled(h) == 0)
    }

    @Test func theIntegrityCheckFindsASplitDayComplete() async throws {
        let h = try await harness()
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        for id in [DestinationID.googleDrive, h.nasId] {
            let report = try await h.coordinator.runIntegrityCheck(id)
            #expect(report.missing == 0 && report.sizeMismatch == 0 && report.hashMismatch == 0, "\(id)")
            #expect(report.checked >= 13)
        }
    }

    // MARK: Hidden upload

    @Test func changingHiddenUploadReevaluatesOnceAndOnlyTheHiddenPhotoMoves() async throws {
        let h = try await harness()
        let sapa = GeoPoint(latitude: 22.3364, longitude: 103.8438)
        await h.geocoder.seed(sapa, en: GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lao Cai", locality: "Sa Pa"),
                              local: GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lào Cai", locality: "Sa Pa"))
        await h.add(h.snapshot("hid", daysAgo: 3, hidden: true, location: sapa), recordChange: false)
        try await h.update { $0.includeHidden = false }
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        #expect(try h.read { db in try DayPlaceRepository.fetchAll(db, day: self.day) }.count == 1)
        let before = try moveFiles(h)

        try await h.update { $0.includeHidden = true }
        await h.settle(rounds: 6)
        #expect(try h.read { db in try DayPlaceRepository.fetchAll(db, day: self.day) }.count == 2, "a third folder appears")
        let afterOn = try moveFiles(h)
        #expect(afterOn > before)
        let hiddenMoves = try h.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE op = 'moveFile' AND subject LIKE ?", arguments: ["%hid%"]) ?? 0
        }
        #expect(hiddenMoves == afterOn - before, "only the hidden photo's files moved")

        await h.settle(rounds: 3)
        #expect(try moveFiles(h) == afterOn, "evaluated once, not on every pass")
        try await h.update { $0.includeHidden = false }
        await h.settle(rounds: 6)
        #expect(try unsettled(h) == 0)
        let names = await folderNames(h.drive)
        #expect(names.count == Set(names.map { $0.lowercased() }).count)
    }

    // MARK: Pending rename

    @Test func aGroupRenamedWhileTheRenameIsPendingAtOneDestinationLeavesNoDuplicateFolder() async throws {
        let h = try await harness()
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        // The Đà Lạt folder is renamed; the rename keeps failing at the NAS.
        let renamed = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Đà Lạt Mới")
        await h.nas.failNext(.rename, with: .server(status: 500), times: 4)
        try h.write { db in
            try GeoCacheRepository.save(db, GeoCacheEntry(cell: GeoCell(daLat), locale: "local", place: renamed, fetchedAt: h.clock.now))
            try DirtyQueue.mark(db, [.place], id: self.day.description)
        }
        await h.settle(rounds: 3)
        // A new group appears under the old name while the NAS still carries it.
        let reused = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lào Cai", locality: "Đà Lạt")
        let sapa = GeoPoint(latitude: 22.3364, longitude: 103.8438)
        await h.geocoder.seed(sapa, en: GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lao Cai", locality: "Sa Pa"), local: reused)
        await h.add(h.snapshot("sapa", daysAgo: 3, location: sapa))
        await h.settle(rounds: 4)
        let nasNames = await h.nas.folders.map(\.name).filter { $0.hasPrefix(day.description) }
        #expect(nasNames.count == Set(nasNames.map { $0.lowercased() }).count, "no two folders with one name: \(nasNames)")
    }

    // MARK: Review fixes

    @Test func aNamedDayThatBecomesUnnamedLosesItsNameEverywhere() async throws {
        let h = try await harness(hanoiCount: 0, daLatCount: 6, nas: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(try h.dayStat(day)?.placeName == "Đà Lạt")
        #expect(await folderNames(h.drive) == [daLatFolder])

        // A photo about 500 km away in a cell without a province: the box is over 300 km, so the day is unnamed.
        let sea = GeoPoint(latitude: 15.5, longitude: 112.0)
        await h.geocoder.seed(sea, en: GeoPlace(), local: GeoPlace())
        await h.add(h.snapshot("sea", daysAgo: 3, location: sea))
        await h.settle(rounds: 6)
        let stat = try #require(try h.dayStat(day))
        #expect(stat.placeState == .unnamed && stat.placeName == nil && stat.placeKey == nil, "\(stat)")
        #expect(await folderNames(h.drive) == [day.description], "renamed to the bare date")

        try h.addNAS(scope: .full)
        await h.env.destinations.add(h.nas)
        try await h.coordinator.destinationAdded(h.nasId)
        await h.settle(rounds: 6)
        #expect(await folderNames(h.nas) == [day.description], "a destination added later agrees")
    }

    @Test func anUnnamedExtraGroupGetsItsRowAndTheCountryOnlyFreezeHoldsIt() async throws {
        let h = try await harness(hanoiCount: 0, daLatCount: 6)
        // Two far-apart photos in one other province: a group whose box is over 300 km, so it has no name.
        let west = GeoPoint(latitude: 22.3, longitude: 103.8)
        let east = GeoPoint(latitude: 22.3, longitude: 107.2)
        let laoCai = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lao Cai", locality: nil)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle(rounds: 6)
        #expect(try h.dayStat(day)?.placeName == "Đà Lạt")
        for (id, point) in [("w", west), ("e", east)] {
            await h.geocoder.seed(point, en: laoCai, local: laoCai)
            await h.add(h.snapshot(id, daysAgo: 3, location: point))
        }
        await h.settle(rounds: 8)
        let rows = try h.read { db in try DayPlaceRepository.fetchAll(db, day: self.day) }
        #expect(rows.count == 1 && rows[0].placeName == nil, "\(rows)")
        #expect(try slots(h)["w"] ?? nil == rows.first?.slot)
        #expect(await folderNames(h.drive) == [daLatFolder, day.description])

        let moves = try moveFiles(h)
        let names = try renames(h)
        for enter in [true, false] {
            try h.write { db in
                try KeyValueRepository.set(db, "place_country_only", enter ? 1 : nil)
                for day in try OrganizationQueries.promotedDays(db) { try DirtyQueue.mark(db, [.place], id: day.description) }
            }
            await h.settle(rounds: 4)
            #expect(try moveFiles(h) == moves && renames(h) == names, "country-only \(enter ? "entered" : "left")")
        }
    }

    @Test func aRenameThatFailedForGoodStillReservesTheNameOnDisk() async throws {
        let h = try await harness()
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let snapshot = await h.env.settingsSnapshot()
        let outcome = try h.write { db -> DaySplitWriter.Outcome in
            let now = h.clock.now
            // Hà Nội was renamed: done on Drive, failed for good on the NAS, whose folder keeps the old name.
            try DayStatRepository.setPlace(db, day: self.day, state: .named, key: "VN|Hanoi", name: "Hanoi City")
            try db.execute(sql: "UPDATE remote_folder SET display_name = ? WHERE destination_id = 'gdrive' AND logical_path = ?",
                           arguments: ["\(self.day) Hanoi City", "camera/\(self.day)"])
            var failed = try MoveJobRepository.insert(db, MoveJob(
                destinationId: h.nasId, operation: .renameFolder, subject: "camera/\(self.day)",
                fromValue: self.hanoiFolder, toValue: "\(self.day) Hanoi City", createdAt: now))
            try db.execute(sql: "UPDATE move_job SET state = 'failed' WHERE id = ?", arguments: [failed.id!])
            failed.id = nil
            // Đà Lạt's cell now answers "Hà Nội", the name the NAS folder still carries.
            let renamed = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Hà Nội", locality: "Hanoi City")
            let reused = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Hà Nội")
            try GeoCacheRepository.save(db, GeoCacheEntry(cell: GeoCell(hanoi), locale: "local", place: renamed, fetchedAt: now))
            try GeoCacheRepository.save(db, GeoCacheEntry(cell: GeoCell(daLat), locale: "local", place: reused, fetchedAt: now))
            return try PlaceNamer.evaluateDay(db, day: self.day, context: try h.env.context(db, snapshot))
        }
        #expect(outcome.needsRetry, "the group waits: its name is still the NAS folder's name")
        #expect(try h.read { db in try DayPlaceRepository.fetchAll(db, day: self.day) }.compactMap(\.placeName) == ["Đà Lạt"])
    }
}
