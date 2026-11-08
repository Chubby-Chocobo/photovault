import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct DestinationTests {
    @Test func addSetsBaselineAndRoundTrips() throws {
        let store = try Store.inMemory()
        let id = DestinationID.local()
        var d = makeDestination(id)
        d.scope = .since(ArchiveDay(year: 2026, month: 3, day: 1)!)
        d.status = .paused(.userPaused)
        d.rules.categories = [.camera]
        d.rules.skipLargerThanBytes = 1_000
        d.config = DestinationConfig(bookmark: Data([1, 2, 3]), displayPath: "/Volumes/NAS", localMarkerId: "m")
        d.accountEmail = "a@b.c"
        let added = try store.write { try DestinationRepository.add($0, d, now: t0) }
        #expect(added.baselineAt == t0)
        let loaded = try store.read { try DestinationRepository.fetch($0, id: id) }
        #expect(loaded == added)
        #expect(try store.read { try DestinationRepository.fetchAll($0) }.count == 1)
    }

    @Test func statusSinceMovesOnlyOnChange() throws {
        let store = try Store.inMemory()
        try store.write { db in
            _ = try DestinationRepository.add(db, makeDestination(), now: t0)
            let later = t0.addingTimeInterval(100)
            try DestinationRepository.setStatus(db, id: .googleDrive, status: .unavailable(.offline), now: later)
            try DestinationRepository.setStatus(db, id: .googleDrive, status: .unavailable(.offline), now: later.addingTimeInterval(100))
            let d = try #require(try DestinationRepository.fetch(db, id: .googleDrive))
            #expect(d.status == .unavailable(.offline) && d.statusSince == later)
            #expect(!d.acceptsUploads)
        }
    }

    @Test func removeDeletesOnlyThatDestinationsState() throws {
        let store = try Store.inMemory()
        let nas = DestinationID.local()
        try store.write { db in
            for id in [DestinationID.googleDrive, nas] {
                _ = try DestinationRepository.add(db, makeDestination(id), now: t0)
                try JobRepository.upsert(db, desired: desired(id, .local("1")), now: t0)
                try RemoteFolderRepository.save(db, RemoteFolder(destinationId: id, logicalPath: "camera", displayName: "camera"))
                try MoveJobRepository.insert(db, MoveJob(destinationId: id, operation: .moveFile, subject: "s", fromValue: "a", toValue: "b", createdAt: t0))
                try ShortcutRepository.save(db, ShortcutRecord(destinationId: id, view: .favorites, assetKey: .local("1")))
            }
            try AssetRepository.upsert(db, makeAsset("1"), timeZone: utc)
            try DestinationRepository.remove(db, id: nas)
            for table in ["destination", "upload_job", "remote_folder", "move_job", "shortcut"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 1, "\(table)")
                #expect(try String.fetchOne(db, sql: "SELECT \(table == "destination" ? "id" : "destination_id") FROM \(table)") == "gdrive")
            }
            #expect(try AssetRepository.count(db) == 1)
        }
    }

    @Test func resetDriveStateClearsLearnedStateAndRequiresRecovery() throws {
        let store = try Store.inMemory()
        try store.write { db in
            _ = try DestinationRepository.add(db, makeDestination(), now: t0)
            try JobRepository.upsert(db, desired: desired(.googleDrive, .local("1")), now: t0)
            try RemoteFolderRepository.save(db, RemoteFolder(destinationId: .googleDrive, logicalPath: "camera", remoteId: "x", displayName: "camera"))
            try DestinationRepository.resetState(db, id: .googleDrive)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM upload_job") == 0)
            #expect(try RemoteFolderRepository.fetchAll(db, destinationId: .googleDrive).isEmpty)
            let d = try #require(try DestinationRepository.fetch(db, id: .googleDrive))
            #expect(d.recoveryRequired && !d.acceptsUploads)
        }
    }
}

@Suite struct OrganizationTests {
    @Test func activityKeepsNewest500() throws {
        let store = try Store.inMemory()
        try store.write { db in
            for i in 0..<510 {
                try ActivityRepository.record(db, ActivityEvent(at: t0.addingTimeInterval(Double(i)), kind: .renamed, message: "m\(i)"))
            }
            let events = try ActivityRepository.recent(db)
            #expect(events.count == 500)
            #expect(events.first?.message == "m509" && events.last?.message == "m10")
        }
    }

    @Test func geoCacheRoundTrip() throws {
        let store = try Store.inMemory()
        let cell = GeoCell(latIndex: 1050, lonIndex: 10650)
        let entry = GeoCacheEntry(cell: cell, locale: "vi", place: GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "HCM", locality: nil), fetchedAt: t0)
        try store.write { try GeoCacheRepository.save($0, entry) }
        #expect(try store.read { try GeoCacheRepository.fetch($0, cell: cell, locale: "vi") } == entry)
        #expect(try store.read { try GeoCacheRepository.fetch($0, cell: cell, locale: "en") } == nil)
    }

    @Test func moveJobLifecycle() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let job = try MoveJobRepository.insert(db, MoveJob(destinationId: .googleDrive, operation: .renameFolder, subject: "camera/2027", fromValue: "a", toValue: "b", createdAt: t0))
            let id = try #require(job.id)
            #expect(try MoveJobRepository.complete(db, id: id) == false)
            #expect(try MoveJobRepository.start(db, id: id))
            for attempt in 1...MoveJob.maxAttempts {
                let state = try MoveJobRepository.fail(db, id: id, message: "e")
                #expect(state == .pending, "attempt \(attempt)")
                try MoveJobRepository.start(db, id: id)
            }
            #expect(try MoveJobRepository.fail(db, id: id, message: "e") == .failed)
            #expect(try MoveJobRepository.fetch(db, id: id)?.attempts == 9)

            let second = try MoveJobRepository.insert(db, MoveJob(destinationId: .googleDrive, operation: .moveFile, subject: "s", fromValue: "a", toValue: "b", createdAt: t0))
            try MoveJobRepository.start(db, id: try #require(second.id))
            #expect(try MoveJobRepository.resetInProgressOnStartup(db) == 1)
            #expect(try MoveJobRepository.complete(db, id: try #require(second.id)) == false)
        }
    }

    @Test func shortcutAndFolderUpsert() throws {
        let store = try Store.inMemory()
        try store.write { db in
            var s = ShortcutRecord(destinationId: .googleDrive, view: .byDevice, assetKey: .local("1"))
            try ShortcutRepository.save(db, s)
            s.state = .done
            s.shortcutId = "sc"
            try ShortcutRepository.save(db, s)
            #expect(try ShortcutRepository.fetch(db, destinationId: .googleDrive, view: .byDevice, assetKey: .local("1")) == s)
            #expect(try ShortcutRepository.fetch(db, destinationId: .googleDrive, state: .done).count == 1)

            var f = RemoteFolder(destinationId: .googleDrive, logicalPath: "camera/2027", remoteId: "r", displayName: "2027")
            try RemoteFolderRepository.save(db, f)
            f.created = true
            f.displayName = "2027 - HCM"
            try RemoteFolderRepository.save(db, f)
            #expect(try RemoteFolderRepository.fetch(db, destinationId: .googleDrive, logicalPath: "camera/2027") == f)
        }
    }

    @Test func deviceGroupsKeepOwnerRename() throws {
        let store = try Store.inMemory()
        try store.write { db in
            try DeviceGroupRepository.assign(db, makeModelKey: "apple|iphone 15", groupId: "g1", defaultDisplayName: "iPhone 15")
            try DeviceGroupRepository.renameGroup(db, id: "g1", displayName: "Phone of Mom")
            let group = try DeviceGroupRepository.assign(db, makeModelKey: "apple|iphone 15 pro", groupId: "g1", defaultDisplayName: "iPhone 15")
            #expect(group.displayName == "Phone of Mom")
            #expect(try DeviceGroupRepository.models(db, groupId: "g1").count == 2)
            #expect(try DeviceGroupRepository.group(db, forMakeModelKey: "apple|iphone 15")?.groupId == "g1")
            try DeviceGroupRepository.setViewFolderGroup(db, ViewFolderGroup(view: .byPlace, groupKey: "VN", displayName: "Việt Nam"))
            #expect(try DeviceGroupRepository.viewFolderGroup(db, view: .byPlace, groupKey: "VN")?.displayName == "Việt Nam")
        }
    }

    @Test func keyValueStore() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let token = Data([0, 1, 255])
            try KeyValueRepository.set(db, KeyValueRepository.Key.changeToken, token)
            #expect(try KeyValueRepository.data(db, KeyValueRepository.Key.changeToken) == token)
            #expect(try KeyValueRepository.scanState(db) == .notStarted)
            try KeyValueRepository.setScanState(db, .running)
            #expect(try KeyValueRepository.scanState(db) == .running)
            try KeyValueRepository.setArchiveTimeZone(db, vietnam)
            #expect(try KeyValueRepository.archiveTimeZone(db) == vietnam)
            try KeyValueRepository.set(db, KeyValueRepository.Key.schemaVersion, 1)
            #expect(try KeyValueRepository.int(db, KeyValueRepository.Key.schemaVersion) == 1)
            try KeyValueRepository.markSinceIfAbsent(db, KeyValueRepository.Key.macDiskFullSince, at: t0)
            try KeyValueRepository.markSinceIfAbsent(db, KeyValueRepository.Key.macDiskFullSince, at: t0.addingTimeInterval(9))
            #expect(try KeyValueRepository.date(db, KeyValueRepository.Key.macDiskFullSince) == t0)
            try KeyValueRepository.set(db, KeyValueRepository.Key.macDiskFullSince, nil)
            #expect(try KeyValueRepository.date(db, KeyValueRepository.Key.macDiskFullSince) == nil)
        }
    }
}
