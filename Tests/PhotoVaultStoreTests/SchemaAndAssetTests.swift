import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct SchemaTests {
    @Test func migrationCreatesAllTablesAndIndexes() throws {
        let store = try Store.inMemory()
        let tables = try store.read { try String.fetchSet($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        for name in ["destination", "asset", "asset_alias", "name_alloc", "album_member", "resource", "upload_job",
                     "day_stat", "geo_cache", "remote_folder", "move_job", "device_group", "device_model",
                     "view_folder_group", "shortcut", "activity", "kv"] {
            #expect(tables.contains(name), "missing \(name)")
        }
        let indexes = try store.read { try String.fetchSet($0, sql: "SELECT name FROM sqlite_master WHERE type = 'index'") }
        for name in ["asset_cloud_id", "asset_placement", "asset_key_hash", "upload_job_identity", "upload_job_state"] {
            #expect(indexes.contains(name), "missing \(name)")
        }
    }

    @Test func auditColumnsExist() throws {
        let store = try Store.inMemory()
        let expected = [
            "upload_job": ["uploading_gen"], "destination": ["recovery_required", "status_since", "last_success_at"],
            "resource": ["next_export_attempt_at", "too_large_for_disk", "last_error"],
            "asset": ["burst_is_pick"], "remote_folder": ["created"],
        ]
        for (table, columns) in expected {
            let actual = try store.read { try Set($0.columns(in: table).map(\.name)) }
            #expect(actual.isSuperset(of: columns), "\(table)")
        }
    }

    @Test func fileDatabaseUsesWal() throws {
        let dir = try tempDirectory()
        let store = try Store.open(at: dir.appendingPathComponent("db.sqlite"))
        let mode = try store.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }

    @Test func jobIdentityIsUnique() throws {
        let store = try Store.inMemory()
        try store.write { db in
            var a = UploadJob(destinationId: .googleDrive, assetKey: .local("1"), resType: .photo, origin: .backfill, updatedAt: t0)
            try JobRepository.save(db, &a)
            var b = a
            b.id = nil
            #expect(throws: DatabaseError.self) { try JobRepository.save(db, &b) }
        }
    }
}

@Suite struct AssetTests {
    @Test func cameraAssetsWithARealLensExcludePlaceholders() throws {
        let store = try Store.inMemory()
        let lenses: [(String, String?, AssetCategory)] = [
            ("a", "iPhone 15 Pro back camera 6.86mm f/1.78", .camera), ("b", "0.0 mm f/0.0", .camera), ("c", " - ", .camera),
            ("d", "", .camera), ("e", nil, .camera), ("f", "iPhone 15 Pro back camera 6.86mm f/1.78", .camera),
            ("g", "Some lens", .screenshot),
        ]
        try store.write { db in
            for (id, lens, category) in lenses {
                var asset = makeAsset(id, category: category)
                asset.lensModel = lens
                try AssetRepository.upsert(db, asset, timeZone: utc)
            }
            var deleted = makeAsset("h")
            deleted.lensModel = "Gone lens"
            try AssetRepository.upsert(db, deleted, timeZone: utc)
            try db.execute(sql: "UPDATE asset SET deleted_at = ? WHERE asset_key = 'l:h'", arguments: [t0])
        }
        #expect(try store.read { try AssetRepository.countCameraWithLens($0) } == 2)
    }

    @Test func roundTripsEveryField() throws {
        let store = try Store.inMemory()
        var asset = makeAsset("A", insertedAt: t0)
        asset.cloudId = "cloud-A"
        asset.mediaSubtypes = [.photoLive, .photoHDR]
        asset.categoryReason = .cameraDefault
        asset.categoryProvisional = true
        asset.location = GeoPoint(latitude: 10.5, longitude: 106.5)
        asset.geoCell = GeoCell(asset.location!)
        asset.burstIdentifier = "burst"
        asset.burstIsPick = false
        asset.cameraMake = "Apple"
        asset.hasAdjustments = true
        asset.adjustmentHash = "h"
        asset.editCheckPending = true
        asset.pixelWidth = 4000
        asset.duration = 3.5
        try store.write { try AssetRepository.upsert($0, asset, timeZone: utc) }
        let loaded = try store.read { try AssetRepository.fetch($0, key: .local("A")) }
        #expect(loaded == asset)
    }

    @Test func upsertKeepsPlacementAndInsertedAt() throws {
        let store = try Store.inMemory()
        try store.write { db in
            try AssetRepository.upsert(db, makeAsset("A", insertedAt: t0), timeZone: utc)
            _ = try AssetPlacementRepository.allocatePlacement(
                db, assetKey: .local("A"), baseStem: "stem", category: .camera, day: .unknown, now: t0)
            var again = makeAsset("A", insertedAt: t0.addingTimeInterval(500))
            again.isFavorite = true
            try AssetRepository.upsert(db, again, timeZone: utc)
            let loaded = try #require(try AssetRepository.fetch(db, key: .local("A")))
            #expect(loaded.placement?.nameStem == "stem")
            #expect(loaded.isFavorite)
            #expect(loaded.insertedAt == t0)
        }
    }

    @Test func creationDayUsesArchiveTimezone() throws {
        let store = try Store.inMemory()
        // 2027-01-15 20:00 UTC is already 2027-01-16 in Ho Chi Minh.
        let created = Date(timeIntervalSince1970: 1_705_348_800 + 3 * 86_400 - 4 * 3600)
        try store.write { db in
            try AssetRepository.upsert(db, makeAsset("A", created: created), timeZone: vietnam)
            let day = try String.fetchOne(db, sql: "SELECT creation_day FROM asset")
            #expect(day == ArchiveDay(date: created, timeZone: vietnam).description)
            try AssetRepository.recomputeCreationDays(db, timeZone: utc)
            #expect(try String.fetchOne(db, sql: "SELECT creation_day FROM asset") == ArchiveDay(date: created, timeZone: utc).description)
        }
    }

    @Test func reattachByLocalIdAliasAndCloudId() throws {
        let store = try Store.inMemory()
        try store.write { db in
            var a = makeAsset("L1")
            a.cloudId = "C1"
            try AssetRepository.upsert(db, a, timeZone: utc)
            try AssetRepository.addAlias(db, alias: "L-old", to: a.assetKey)
            #expect(try AssetRepository.find(db, localId: "L1", cloudId: nil)?.assetKey == a.assetKey)
            #expect(try AssetRepository.find(db, localId: "L-old", cloudId: nil)?.assetKey == a.assetKey)
            #expect(try AssetRepository.find(db, localId: "unknown", cloudId: "C1")?.assetKey == a.assetKey)
            #expect(try AssetRepository.find(db, localId: "unknown", cloudId: "other") == nil)
            #expect(try AssetRepository.aliases(db, of: a.assetKey).map(\.alias) == ["L-old"])
        }
    }

    @Test func hashedKeyLookup() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let a = makeAsset("L1")
            try AssetRepository.upsert(db, a, timeZone: utc)
            let prefix = String(a.assetKey.hashedForm.dropFirst(2))
            #expect(try AssetRepository.fetch(db, hashPrefix: prefix).map(\.assetKey) == [a.assetKey])
        }
    }

    @Test func albumsAreReplaced() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = AssetKey.local("1")
            try AssetRepository.setAlbums(db, for: key, members: [AlbumMember(albumLocalId: "a", albumTitle: "WhatsApp", assetKey: key)])
            try AssetRepository.setAlbums(db, for: key, members: [AlbumMember(albumLocalId: "b", albumTitle: "Zalo", assetKey: key)])
            #expect(try AssetRepository.albums(db, for: key).map(\.albumTitle) == ["Zalo"])
        }
    }

    @Test func corruptEnumSurfacesAsError() throws {
        let store = try Store.inMemory()
        try store.write { db in
            try AssetRepository.upsert(db, makeAsset("A"), timeZone: utc)
            try db.execute(sql: "UPDATE asset SET category = 'bogus'")
            #expect(throws: StoreError.corruptRow(table: "asset", column: "category")) {
                try AssetRepository.fetch(db, key: .local("A"))
            }
        }
    }
}
