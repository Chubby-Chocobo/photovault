import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct SourcesMigrationTests {
    @Test func upgradeKeepsEveryAssetAsPhotos() async throws {
        let queue = try DatabaseQueue()
        let migrator = Schema.makeMigrator()
        try migrator.migrate(queue, upTo: "v4-provisional-index")
        try await queue.write { db in
            for id in ["A", "B", "C"] {
                try AssetRepository.upsertLegacyRowForMigrationTest(db, id)
            }
        }
        try migrator.migrate(queue)
        try await queue.read { db in
            let sources = try String.fetchAll(db, sql: "SELECT DISTINCT source_id FROM asset")
            #expect(sources == ["photos"])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") == 3)
            let assets = try Row.fetchAll(db, sql: "SELECT * FROM asset").map(AssetRepository.decode)
            #expect(assets.allSatisfy { $0.sourceId == .photos })
            let indexes = try Set(Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'").map { $0["name"] as String })
            #expect(indexes.isSuperset(of: ["asset_source", "resource_sha256", "import_item_group", "import_item_asset"]))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") == 0)
        }
    }

    @Test func shaLookupUsesTheIndex() async throws {
        let store = try Store.inMemory()
        try await store.read { db in
            let plan = try Row.fetchAll(db, sql: """
            EXPLAIN QUERY PLAN SELECT a.asset_key FROM resource r JOIN asset a ON a.asset_key = r.asset_key
            WHERE r.sha256 = 'x' AND a.deleted_at IS NULL LIMIT 1
            """).map { $0["detail"] as String }.joined(separator: " | ")
            #expect(plan.contains("resource_sha256"), "\(plan)")
        }
    }
}

extension AssetRepository {
    /// Inserts a row with only the v1 columns, as an older build would have written it.
    static func upsertLegacyRowForMigrationTest(_ db: Database, _ id: String) throws {
        let key = AssetKey.local(id)
        try db.execute(sql: """
        INSERT INTO asset (asset_key, asset_key_hash, local_id, media_type, media_subtypes, category_provisional, is_hidden,
            is_favorite, burst_is_pick, pixel_width, pixel_height, duration, has_adjustments, edit_check_pending,
            first_seen_at, last_seen_at)
        VALUES (?, ?, ?, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, ?, ?)
        """, arguments: [key.rawValue, key.sha256Hex, id, t0, t0])
    }
}

@Suite struct SourceRepositoryTests {
    func record(_ id: SourceID = .folder(), at: Date = t0) -> SourceRecord {
        SourceRecord(id: id, kind: .localFolder, mode: .oneTime, displayName: "Trip", config: SourceConfig(bookmark: Data([1, 2, 3])),
                     status: .scanning, createdAt: at)
    }

    @Test func insertFetchAndStatus() async throws {
        let store = try Store.inMemory()
        let source = record()
        try await store.write { db in
            try SourceRepository.insert(db, source)
            #expect(try SourceRepository.fetch(db, id: source.id) == source)
            try SourceRepository.setListed(db, id: source.id, now: t0 + 5)
            try SourceRepository.setStatus(db, id: source.id, status: .offline, reason: "unavailable", now: t0 + 6)
            var fetched = try #require(try SourceRepository.fetch(db, id: source.id))
            #expect(fetched.status == .offline && fetched.statusReason == "unavailable" && fetched.listedAt == t0 + 5 && fetched.finishedAt == nil)
            try SourceRepository.setStatus(db, id: source.id, status: .completed, reason: nil, now: t0 + 9)
            fetched = try #require(try SourceRepository.fetch(db, id: source.id))
            #expect(fetched.status == .completed && fetched.statusReason == nil && fetched.finishedAt == t0 + 9)
            #expect(try SourceRepository.fetch(db, id: .folder()) == nil)
        }
    }

    @Test func fetchAllAndConfig() async throws {
        let store = try Store.inMemory()
        let a = record(at: t0), b = record(at: t0 + 10)
        try await store.write { db in
            try SourceRepository.insert(db, b)
            try SourceRepository.insert(db, a)
            #expect(try SourceRepository.fetchAll(db).map(\.id) == [a.id, b.id])
            try SourceRepository.setConfig(db, id: a.id, SourceConfig(bookmark: Data([9])))
            #expect(try SourceRepository.fetch(db, id: a.id)?.config.bookmark == Data([9]))
        }
    }
}

@Suite struct RefreshedBookmarkTests {
    @Test func aRefreshedBookmarkKeepsTheRestOfTheConfig() async throws {
        let store = try Store.inMemory()
        let config = SourceConfig(
            bookmark: Data([1]), account: "a@b.c", locationPaths: ["Google Drive/My Drive/Trip"], syncedProvider: .googleDrive)
        let source = SourceRecord(id: .folder(), kind: .localFolder, mode: .oneTime, displayName: "Trip", config: config, status: .scanning, createdAt: t0)
        try await store.write { db in
            try SourceRepository.insert(db, source)
            try SourceRepository.setBookmark(db, id: source.id, Data([7, 7]))
            let stored = try #require(try SourceRepository.fetch(db, id: source.id)?.config)
            #expect(stored.bookmark == Data([7, 7]))
            #expect(stored.account == "a@b.c" && stored.locationPaths == ["Google Drive/My Drive/Trip"] && stored.syncedCloudProvider == .googleDrive)
            // A row that is gone is not recreated.
            try SourceRepository.setBookmark(db, id: .folder(), Data([1]))
            #expect(try SourceRepository.fetchAll(db).count == 1)
        }
    }
}

@Suite struct SidecarNameTests {
    @Test func theSidecarNameIsTheDisplayNameUnlessTheConfigSetsOne() {
        func row(_ config: SourceConfig) -> SourceRecord {
            SourceRecord(id: .folder(), kind: .googleDrive, mode: .oneTime, displayName: "3 mục từ Google Drive", config: config, status: .scanning, createdAt: t0)
        }
        #expect(row(SourceConfig()).sidecarName == "3 mục từ Google Drive")
        #expect(row(SourceConfig(sidecarName: "Google Drive")).sidecarName == "Google Drive")
    }
}

@Suite struct ImportItemRepositoryTests {
    let source = SourceID.folder()

    func item(_ path: String, group: String? = nil, state: ImportItemState = .pending) -> ImportItem {
        ImportItem(sourceId: source, relativePath: path, groupKey: group ?? FolderItemGrouper.groupKey(relativePath: path),
                   uti: "public.jpeg", sizeBytes: 10, state: state)
    }

    @Test func insertIsIdempotentAndKeepsProgress() async throws {
        let store = try Store.inMemory()
        try await store.write { db in
            try ImportItemRepository.insertIgnoring(db, [item("a.jpg"), item("b.jpg")])
            try ImportItemRepository.mark(db, sourceId: source, relativePath: "a.jpg", state: .imported, assetKey: .local("K"), isPrimary: true, dateSource: .exif, reason: nil)
            try ImportItemRepository.insertIgnoring(db, [item("a.jpg"), item("b.jpg"), item("c.jpg")])
            let counts = try ImportItemRepository.counts(db, sourceId: source)
            #expect(counts == [.imported: 1, .pending: 2])
        }
    }

    @Test func groupsArePagedWhole() async throws {
        let store = try Store.inMemory()
        try await store.write { db in
            try ImportItemRepository.insertIgnoring(db, [
                item("d/a.jpg"), item("d/a.arw"), item("d/b.jpg"), item("d/c.heic"), item("d/c.mov"), item("e.jpg"),
            ])
            let first = try ImportItemRepository.nextGroups(db, sourceId: source, limit: 2)
            #expect(first.map { $0.map(\.relativePath) } == [["d/a.arw", "d/a.jpg"], ["d/b.jpg"]])
            for group in first { for entry in group { try ImportItemRepository.mark(db, sourceId: source, relativePath: entry.relativePath, state: .duplicate, assetKey: nil, isPrimary: false, dateSource: nil, reason: nil) } }
            let second = try ImportItemRepository.nextGroups(db, sourceId: source, limit: 10)
            #expect(second.map { $0.map(\.relativePath) } == [["d/c.heic", "d/c.mov"], ["e.jpg"]])
            #expect(try ImportItemRepository.nextGroups(db, sourceId: .folder(), limit: 10).isEmpty)
        }
    }

    @Test func skippedGroupsAreLeftOutAndTheLimitCountsOnlyTheOthers() async throws {
        let store = try Store.inMemory()
        try await store.write { db in
            try ImportItemRepository.insertIgnoring(db, [item("a.jpg"), item("b.jpg"), item("c.jpg"), item("d.jpg")])
            let skipped: Set<String> = [FolderItemGrouper.groupKey(relativePath: "a.jpg"), FolderItemGrouper.groupKey(relativePath: "b.jpg")]
            let next = try ImportItemRepository.nextGroups(db, sourceId: source, limit: 2, excluding: skipped)
            #expect(next.map { $0.map(\.relativePath) } == [["c.jpg"], ["d.jpg"]])
        }
    }

    @Test func onlyTheNamedGroupsAreConsidered() async throws {
        let store = try Store.inMemory()
        try await store.write { db in
            try ImportItemRepository.insertIgnoring(db, [item("a.jpg"), item("b.jpg"), item("c.jpg"), item("d.jpg")])
            func key(_ path: String) -> String { FolderItemGrouper.groupKey(relativePath: path) }
            let only = try ImportItemRepository.nextGroups(db, sourceId: source, limit: 10, only: [key("b.jpg"), key("d.jpg")])
            #expect(only.map { $0.map(\.relativePath) } == [["b.jpg"], ["d.jpg"]])
            let limited = try ImportItemRepository.nextGroups(db, sourceId: source, limit: 1, excluding: [key("b.jpg")], only: [key("b.jpg"), key("d.jpg")])
            #expect(limited.map { $0.map(\.relativePath) } == [["d.jpg"]])
            #expect(try ImportItemRepository.nextGroups(db, sourceId: source, limit: 10, only: []).isEmpty)
        }
    }

    @Test func cancelPendingLeavesFinishedItems() async throws {
        let store = try Store.inMemory()
        try await store.write { db in
            try ImportItemRepository.insertIgnoring(db, [item("a.jpg"), item("b.jpg"), item("c.jpg", state: .failed)])
            try ImportItemRepository.mark(db, sourceId: source, relativePath: "a.jpg", state: .imported, assetKey: .local("K"), isPrimary: true, dateSource: .fileDate, reason: nil)
            #expect(try ImportItemRepository.cancelPending(db, sourceId: source) == 1)
            #expect(try ImportItemRepository.counts(db, sourceId: source) == [.imported: 1, .cancelled: 1, .failed: 1])
        }
    }

    @Test func primaryByAssetKey() async throws {
        let store = try Store.inMemory()
        let key = AssetKey.local("K")
        try await store.write { db in
            try ImportItemRepository.insertIgnoring(db, [item("d/a.jpg"), item("d/a.arw"), item("d/z.jpg")])
            try ImportItemRepository.mark(db, sourceId: source, relativePath: "d/a.jpg", state: .imported, assetKey: key, isPrimary: false, dateSource: nil, reason: nil)
            try ImportItemRepository.mark(db, sourceId: source, relativePath: "d/a.arw", state: .imported, assetKey: key, isPrimary: true, dateSource: .exif, reason: nil)
            try ImportItemRepository.mark(db, sourceId: source, relativePath: "d/z.jpg", state: .duplicate, assetKey: key, isPrimary: false, dateSource: nil, reason: nil)
            let primary = try #require(try ImportItemRepository.primary(db, assetKey: key, preferring: source))
            #expect(primary.sourceId == source && primary.relativePath == "d/a.arw" && primary.dateSource == .exif)
            #expect(try ImportItemRepository.primary(db, assetKey: .local("none"), preferring: source) == nil)
        }
    }

    @Test func importedItemsOfAnAssetAndStoredFields() async throws {
        let store = try Store.inMemory()
        try await store.write { db in
            var entry = item("a.jpg")
            entry.createdAtFS = t0
            entry.modifiedAtFS = t0 + 1
            try ImportItemRepository.insertIgnoring(db, [entry])
            let back = try #require(try ImportItemRepository.nextGroups(db, sourceId: source, limit: 1).first?.first)
            #expect(back == entry)
        }
    }
}

@Suite struct AssetSourceColumnTests {
    @Test func sourceIdRoundTripsAndShaLookupSkipsDeleted() async throws {
        let store = try Store.inMemory()
        let source = SourceID.folder()
        let key = AssetKey.content(sha256: String(repeating: "cd", count: 32))!
        let asset = AssetRecord(assetKey: key, localId: ImportLocator(sourceId: source, relativePath: "a.jpg").localId,
                                mediaType: .image, firstSeenAt: t0, lastSeenAt: t0, sourceId: source)
        try await store.write { db in
            try AssetRepository.upsert(db, asset, timeZone: utc)
            #expect(try AssetRepository.fetch(db, key: key)?.sourceId == source)
            try ResourceRepository.upsert(db, ResourceRecord(assetKey: key, type: .photo, originalFilename: "a.jpg", uti: "public.jpeg", sha256: "feed"))
            #expect(try AssetRepository.liveAsset(db, withResourceSHA256: "feed") == key)
            #expect(try AssetRepository.liveAsset(db, withResourceSHA256: "nope") == nil)
            var deleted = asset
            deleted.deletedAt = t0
            try AssetRepository.upsert(db, deleted, timeZone: utc)
            #expect(try AssetRepository.liveAsset(db, withResourceSHA256: "feed") == nil)
        }
    }
}

@Suite struct SourceAdapterRowsTests {
    @Test func everyFolderSourceWithABookmarkNeedsAnAdapterWhateverItsStatus() async throws {
        let store = try Store.inMemory()
        func row(_ status: SourceStatus, bookmark: Data?) -> SourceRecord {
            SourceRecord(id: .folder(), kind: .localFolder, mode: .oneTime, displayName: "x", config: SourceConfig(bookmark: bookmark), status: status, createdAt: t0)
        }
        let rows = [row(.scanning, bookmark: Data([1])), row(.completed, bookmark: Data([2])), row(.cancelled, bookmark: Data([3])), row(.completed, bookmark: nil)]
        try await store.write { db in for r in rows { try SourceRepository.insert(db, r) } }
        let needed = try await store.read { db in try SourceRepository.readableImports(db) }
        #expect(Set(needed.map(\.id)) == Set(rows.prefix(3).map(\.id)))
    }
}

@Suite struct CloudSourceRowsTests {
    @Test func readableImportsIncludeEveryCloudRowAndMacFoldersWithABookmark() async throws {
        let store = try Store.inMemory()
        func row(_ kind: SourceKind, bookmark: Data? = nil) -> SourceRecord {
            SourceRecord(id: .folder(), kind: kind, mode: .oneTime, displayName: "x", config: SourceConfig(bookmark: bookmark), status: .completed, createdAt: t0)
        }
        let rows = [row(.localFolder, bookmark: Data([1])), row(.localFolder), row(.googleDrive), row(.dropbox)]
        try await store.write { db in for r in rows { try SourceRepository.insert(db, r) } }
        let readable = try await store.read { db in try SourceRepository.readableImports(db) }
        #expect(Set(readable.map(\.id)) == Set([rows[0], rows[2], rows[3]].map(\.id)))
    }

    @Test func aCloudRowKeepsItsKindAndConfig() async throws {
        let store = try Store.inMemory()
        let record = SourceRecord(
            id: .folder(), kind: .googleDrive, mode: .oneTime, displayName: "Trip",
            config: SourceConfig(account: "a@b.c", remoteItems: ["1", "2"]), status: .scanning, createdAt: t0)
        try await store.write { db in try SourceRepository.insert(db, record) }
        let back = try await store.read { db in try SourceRepository.fetch(db, id: record.id) }
        #expect(back == record)
    }

    @Test func aConfigWrittenBeforeCloudImportsStillDecodes() throws {
        let old = Data(#"{"bookmark":"AQID"}"#.utf8)
        let config = try JSONDecoder().decode(SourceConfig.self, from: old)
        #expect(config.bookmark == Data([1, 2, 3]) && config.account == nil && config.remoteItems == nil)
        #expect(try JSONDecoder().decode(SourceConfig.self, from: Data("{}".utf8)) == SourceConfig())
    }
}
