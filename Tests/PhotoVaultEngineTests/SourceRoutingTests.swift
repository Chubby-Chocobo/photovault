import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

extension Harness {
    /// Registers a folder source row (open) and a live imported asset with one pending upload job per destination.
    @discardableResult
    func seedImported(
        _ name: String, source: FakeContentSource, status: SourceStatus = .importing, destinations: [DestinationID] = [.googleDrive],
        daysAgo: Double = 1, data: Data? = nil, writeSourceRow: Bool = true
    ) async throws -> AssetKey {
        let bytes = data ?? Data("imported-\(name)".utf8)
        let hash = TestFiles.hashes(of: bytes).sha256
        let key = try #require(AssetKey.content(sha256: hash))
        let locator = ImportLocator(sourceId: source.id, relativePath: "trip/\(name).jpg")
        source.add(localId: locator.localId, data: bytes)
        await sources.add(source)
        let now = clock.now
        let created = now.addingTimeInterval(-daysAgo * 86_400)
        try write { db in
            if writeSourceRow, try SourceRepository.fetch(db, id: source.id) == nil {
                try SourceRepository.insert(db, SourceRecord(id: source.id, kind: .localFolder, mode: .oneTime, displayName: "Trip", status: status, createdAt: now, listedAt: now))
            }
            var asset = AssetRecord(
                assetKey: key, localId: locator.localId, creationDate: created, mediaType: .image, category: .camera,
                placement: Placement(category: .camera, day: .day(ArchiveDay(date: created, timeZone: utc)), nameStem: "\(ArchiveDay(date: created, timeZone: utc)) 10.00.00_\(name)"),
                placedAt: now, insertedAt: now, firstSeenAt: now, lastSeenAt: now, sourceId: source.id)
            asset.pixelWidth = 100
            asset.pixelHeight = 80
            try AssetRepository.upsert(db, asset, timeZone: utc)
            try ResourceRepository.upsert(db, ResourceRecord(assetKey: key, type: .photo, originalFilename: "\(name).jpg", uti: "public.jpeg"))
            for destination in destinations {
                var job = UploadJob(destinationId: destination, assetKey: key, resType: .photo, origin: .incremental, targetGen: 1, updatedAt: now)
                try JobRepository.save(db, &job)
            }
        }
        return key
    }
}

extension Harness {
    /// A placed Photos asset with a pending Drive job, as the cycle would leave it.
    func seedPhotosAsset(_ id: String, daysAgo: Double) async throws {
        await fakePhotos.add(snapshot(id, daysAgo: daysAgo), recordChange: false)
        let now = clock.now
        let created = now.addingTimeInterval(-daysAgo * 86_400)
        try write { db in
            let key = AssetKey.local(id)
            try AssetRepository.upsert(db, AssetRecord(
                assetKey: key, localId: id, creationDate: created, mediaType: .image, category: .camera,
                placement: Placement(category: .camera, day: .day(ArchiveDay(date: created, timeZone: utc)), nameStem: "stem-\(id)"),
                placedAt: now, insertedAt: now, firstSeenAt: now, lastSeenAt: now), timeZone: utc)
            try ResourceRepository.upsert(db, ResourceRecord(assetKey: key, type: .photo, originalFilename: "IMG_\(id).HEIC", uti: "public.heic"))
            var job = UploadJob(destinationId: .googleDrive, assetKey: key, resType: .photo, origin: .incremental, targetGen: 1, updatedAt: now)
            try JobRepository.save(db, &job)
        }
    }
}

@Suite struct SourceRoutingTests {
    @Test func folderAssetsReadFromTheirSourceAndPhotosFromPhotos() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("p1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        let folder = FakeContentSource()
        try await h.seedImported("holiday", source: folder)
        await h.run()
        #expect(folder.exportedLocalIds.count == 1 && folder.exportedLocalIds[0].hasSuffix("trip/holiday.jpg"))
        #expect(await h.fakePhotos.exports(of: "p1") == 1)
        #expect(await h.fakePhotos.exportCount.keys.allSatisfy { !$0.hasPrefix("folder-") })
        let names = await h.fileNames(h.drive)
        #expect(names.count == 2 && names.contains { $0.hasSuffix("holiday.jpg") }, "\(names)")
    }

    @Test func anUnreachableSourceGoesOfflineAndPhotosKeepExporting() async throws {
        let h = try await Harness { $0.maxConcurrentExports = 1 }
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        try await h.seedPhotosAsset("p1", daysAgo: 30)
        let folder = FakeContentSource()
        folder.setOnline(false)
        // Newer than the Photos asset, so it is tried first.
        let key = try await h.seedImported("gone", source: folder, daysAgo: 1)
        let staging = StagingManager(env: h.env)
        let worker = ExportWorker(env: h.env, resourceGuard: ResourceGuard(env: h.env, staging: staging), staging: staging)
        let result = try await worker.runPass()
        #expect(!result.photosUnavailable)
        #expect(result.exported == 1 && result.failed == 1, "\(result)")
        #expect(await h.fakePhotos.exports(of: "p1") == 1)
        let source = try #require(try h.read { db in try SourceRepository.fetch(db, id: folder.id) })
        #expect(source.status == .offline)
        #expect(try h.asset(key)?.deletedAt == nil)
        // While offline its assets are not export candidates.
        let candidates = try h.read { db in try EngineQueries.exportCandidates(db, now: h.clock.now.addingTimeInterval(3600), backfillAllowed: true, limit: 10) }
        #expect(candidates.isEmpty)
        // Back online and open again: the export goes through.
        folder.setOnline(true)
        try h.write { db in try SourceRepository.setStatus(db, id: folder.id, status: .importing, reason: nil, now: h.clock.now) }
        h.clock.advance(by: 3600)
        let again = try await worker.runPass()
        #expect(again.exported == 1)
    }

    @Test func aSourceThatIsNotRegisteredIsUnavailableNotLost() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let folder = FakeContentSource()
        try await h.seedImported("orphan", source: folder)
        await h.sources.remove(folder.id)
        let staging = StagingManager(env: h.env)
        let worker = ExportWorker(env: h.env, resourceGuard: ResourceGuard(env: h.env, staging: staging), staging: staging)
        let result = try await worker.runPass()
        #expect(!result.photosUnavailable && result.failed == 1)
        #expect(try h.read { db in try SourceRepository.fetch(db, id: folder.id) }?.status == .offline)
    }

    @Test func sidecarCarriesTheSourceBlockOnlyForImports() async throws {
        let h = try await Harness.organized()
        try await h.update { $0.viewByDeviceEnabled = false; $0.viewByPlaceEnabled = false; $0.viewFavoritesEnabled = false; $0.placeNamesEnabled = false }
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("p1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        let folder = FakeContentSource()
        let key = try await h.seedImported("holiday", source: folder)
        try h.write { db in
            try ImportItemRepository.insertIgnoring(db, [ImportItem(sourceId: folder.id, relativePath: "trip/holiday.jpg", groupKey: "trip/holiday", uti: "public.jpeg", sizeBytes: 1)])
            try ImportItemRepository.mark(db, sourceId: folder.id, relativePath: "trip/holiday.jpg", state: .imported, assetKey: key, isPrimary: true, dateSource: .exif, reason: nil)
        }
        await h.settle()
        let uploaded = Set(await h.sidecarItems(h.drive).filter { $0.name.hasSuffix(".json") }.compactMap { $0.content?.sha256 })
        #expect(uploaded.count == 2)
        func build(_ asset: AssetKey) throws -> SidecarFile {
            try h.read { db in
                let record = try #require(try AssetRepository.fetch(db, key: asset))
                return try #require(try SidecarFactory.build(
                    db, asset: record, destinationId: .googleDrive, type: .sidecarJson, settings: GlobalSettings(), timeZone: utc,
                    nameBuilder: NameStemBuilder(timeZone: utc, utiResolver: FakeUTIResolver())))
            }
        }
        let imported = try build(key)
        let photos = try build(.local("p1"))
        #expect(uploaded == [imported.sha256, photos.sha256])
        let importedText = String(decoding: imported.data, as: UTF8.self)
        #expect(importedText.contains("\"source\"") && importedText.contains("\"path\": \"trip/holiday.jpg\"") && importedText.contains("\"dateSource\": \"exif\""))
        #expect(!String(decoding: photos.data, as: UTF8.self).contains("\"source\""))
    }
}
