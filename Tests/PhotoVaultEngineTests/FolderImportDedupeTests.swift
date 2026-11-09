import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct FolderImportDedupeTests {
    private func harness(scope: ScopeMode = .full) async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: scope)
        try await h.baseline(.googleDrive)
        return h
    }

    private func when(_ h: Harness, daysAgo: Double = 3) -> Date { h.clock.now.addingTimeInterval(-daysAgo * 86_400) }

    @Test func theSameBytesTwiceInOneFolderAreUploadedOnce() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        try folder.add("a.jpg", "same", metadata: ImportFolder.photo(at: when(h)))
        try folder.add("other/b.jpg", "same", metadata: ImportFolder.photo(at: when(h, daysAgo: 9)))
        let id = try await h.startImport(folder)
        #expect(try h.importCounts(id) == [.imported: 1, .duplicate: 1])
        #expect(await h.drive.files.count == 1)
        #expect(try h.assets(of: id).count == 1)
    }

    @Test func importingTheSameFolderAgainFindsEverythingAlreadyBackedUp() async throws {
        let h = try await harness()
        let first = try ImportFolder()
        try first.add("a.jpg", metadata: ImportFolder.photo(at: when(h)))
        try first.add("b.jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: 4)))
        try await h.startImport(first)
        let second = ImportFolder(again: first)
        let id = try await h.startImport(second)
        #expect(try h.importCounts(id) == [.duplicate: 2])
        #expect(try h.source(id)?.status == .completed)
        #expect(await h.drive.files.count == 2)
        #expect(try h.importActivity().count == 2, "one summary per job")
    }

    @Test func aPhotosAssetAlreadyExportedMatchesByHash() async throws {
        let h = try await harness()
        let bytes = Data("the exact photo".utf8)
        await h.fakePhotos.add(h.snapshot("p1", daysAgo: 8), resources: [.photo: bytes], recordChange: false)
        await h.run()
        h.clock.advance(by: 60)
        await h.settle()
        #expect(await h.drive.files.count == 1)
        let folder = try ImportFolder()
        // A different name and date: only the bytes tie it to the Photos asset.
        try folder.add("renamed.jpg", "the exact photo", metadata: ImportFolder.photo(at: when(h, daysAgo: 20), width: 10, height: 10))
        let id = try await h.startImport(folder)
        #expect(try h.importCounts(id) == [.duplicate: 1])
        #expect(await h.drive.files.count == 1)
    }

    @Test func aPhotosAssetStillWaitingMatchesByFingerprint() async throws {
        let h = try await harness(scope: .newOnly)
        var snapshot = h.snapshot("0001", daysAgo: 3)
        snapshot.pixelWidth = 3000
        snapshot.pixelHeight = 4000
        await h.add(snapshot, recordChange: false)
        await h.fakePhotos.add(snapshot, header: camera, recordChange: false)
        await h.run()
        #expect(await h.drive.files.isEmpty, "the old photo is not exported")
        let folder = try ImportFolder()
        // Same second, same stem, same size with the sides swapped by orientation.
        try folder.add("img_0001.heic", metadata: ImportFolder.photo(at: when(h), width: 4000, height: 3000))
        // Same stem and size, another second.
        try folder.add("other/IMG_0001.HEIC", metadata: ImportFolder.photo(at: when(h).addingTimeInterval(5), width: 4000, height: 3000))
        // Same second and stem, another size.
        try folder.add("third/IMG_0001.HEIC", metadata: ImportFolder.photo(at: when(h), width: 100, height: 100))
        let id = try await h.startImport(folder)
        let items = try h.read { db in try Row.fetchAll(db, sql: "SELECT rel_path, state FROM import_item").map { "\($0["rel_path"] as String) \($0["state"] as String)" } }
        #expect(try h.importCounts(id) == [.duplicate: 1, .imported: 2], "\(items)")
        let duplicate = try h.read { db in
            try Row.fetchOne(db, sql: "SELECT rel_path, asset_key FROM import_item WHERE state = 'duplicate'")
        }
        #expect(duplicate?["rel_path"] as String? == "img_0001.heic")
        #expect(duplicate?["asset_key"] as String? == "l:0001")
    }

    @Test func aVideoMatchesByDuration() async throws {
        let h = try await harness(scope: .newOnly)
        var snapshot = h.snapshot("0002", daysAgo: 3, type: .video)
        snapshot.duration = 12.3
        await h.fakePhotos.add(snapshot, recordChange: false)
        await h.add(snapshot, recordChange: false)
        await h.run()
        let folder = try ImportFolder()
        try folder.add("MOV_0002.MOV", metadata: FileMetadata(captureDate: when(h), duration: 12.5))
        try folder.add("x/MOV_0002.MOV", metadata: FileMetadata(captureDate: when(h), duration: 30))
        let id = try await h.startImport(folder)
        #expect(try h.importCounts(id) == [.duplicate: 1, .imported: 1])
    }

    @Test func aRemovedImportComesBackWhenTheSameFolderIsImportedAgain() async throws {
        let h = try await harness()
        h.tuning.importBatchGroups = 1
        try await h.restart()
        let first = try ImportFolder()
        for index in 0..<2 { try first.add("p\(index).jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: Double(3 + index)))) }
        let hits = HitCounter()
        h.injector.onReach { point in
            if point == .afterImportGroupCommit, hits.next() == 2 { throw SimulatedCrash(point: point.rawValue) }
        }
        let cancelled = try await first.startAndRun(h)
        try await h.coordinator.cancelImport(cancelled)
        h.injector.onReach(nil)
        #expect(await h.drive.files.count == 1)
        let again = ImportFolder(again: first)
        let id = try await h.startImport(again)
        #expect(try h.importCounts(id) == [.imported: 2], "the uploaded file moves to the new job; the removed one is imported again")
        #expect(await h.drive.files.count == 2)
        let keys = try h.read { db in try String.fetchAll(db, sql: "SELECT asset_key FROM asset") }
        #expect(keys.count == 2 && Set(keys).count == 2)
        #expect(try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE deleted_at IS NOT NULL") } == 0)
    }
}
