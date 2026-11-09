import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// The fingerprint is a last resort for unexported Photos assets; it never drops a distinct file.
@Suite struct FolderImportDedupeRulesTests {
    private func harness(scope: ScopeMode = .full) async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: scope)
        try await h.baseline(.googleDrive)
        return h
    }

    private func when(_ h: Harness, daysAgo: Double = 3) -> Date { h.clock.now.addingTimeInterval(-daysAgo * 86_400) }

    @Test func twoFilesWithTheSameNameAndMetadataButDifferentBytesAreBothKept() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        try folder.add("originals/IMG_1234.JPG", "original-bytes", metadata: ImportFolder.photo(at: when(h)))
        try folder.add("edited/IMG_1234.JPG", "edited-bytes", metadata: ImportFolder.photo(at: when(h)))
        let id = try await h.startImport(folder)
        #expect(try h.importCounts(id) == [.imported: 2])
        #expect(await h.drive.files.count == 2)
    }

    @Test func aFileDateAloneNeverMatchesAPhotosAsset() async throws {
        let h = try await harness(scope: .newOnly)
        var snapshot = h.snapshot("0001", daysAgo: 3)
        snapshot.pixelWidth = 4000
        snapshot.pixelHeight = 3000
        await h.fakePhotos.add(snapshot, header: camera, recordChange: false)
        await h.add(snapshot, recordChange: false)
        await h.run()
        let folder = try ImportFolder()
        // No EXIF date: the date comes from the file system, which any copy changes.
        try folder.add("IMG_0001.HEIC", metadata: FileMetadata(pixelWidth: 4000, pixelHeight: 3000))
        let id = try await h.startImport(folder)
        #expect(try h.importCounts(id) == [.imported: 1])
    }

    @Test func aFingerprintNeverMatchesAnotherImport() async throws {
        let h = try await harness()
        let first = try ImportFolder()
        try first.add("IMG_1.JPG", "one", metadata: ImportFolder.photo(at: when(h)))
        try await h.startImport(first)
        let second = try ImportFolder()
        try second.add("sub/IMG_1.JPG", "two", metadata: ImportFolder.photo(at: when(h)))
        let id = try await h.startImport(second)
        #expect(try h.importCounts(id) == [.imported: 1])
    }

    @Test func aPhotosAssetThatIsAlreadyExportedIsNotMatchedByFingerprint() async throws {
        let h = try await harness()
        var snapshot = h.snapshot("0001", daysAgo: 3)
        snapshot.pixelWidth = 4000
        snapshot.pixelHeight = 3000
        await h.add(snapshot)
        await h.settle()
        #expect(await h.drive.files.count == 1)
        let folder = try ImportFolder()
        try folder.add("IMG_0001.HEIC", "different bytes", metadata: ImportFolder.photo(at: when(h), width: 4000, height: 3000))
        let id = try await h.startImport(folder)
        #expect(try h.importCounts(id) == [.imported: 1], "the hash decides once the Photos asset is exported")
    }

    // MARK: Taking over

    @Test func aLiveAssetOfACancelledImportIsTakenOverByTheNextImport() async throws {
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
        // The uploaded asset stays live but belongs to a cancelled import.
        let before = try h.assets(of: cancelled).filter { $0.deletedAt == nil }
        #expect(before.count == 1)
        try h.addNAS(scope: .full)
        let again = ImportFolder(again: first)
        let id = try await h.startImport(again)
        #expect(try h.importCounts(id) == [.imported: 2], "both files belong to the new job")
        #expect(try h.assets(of: cancelled).filter { $0.deletedAt == nil }.isEmpty)
        try await h.coordinator.destinationAdded(h.nasId)
        for _ in 0..<4 { await h.run(); h.clock.advance(by: 3600) }
        #expect(await h.nas.files.count == 2)
        #expect(await h.drive.files.count == 2)
    }
}
