import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

@Suite struct FolderImportTests {
    private func harness(scope: ScopeMode = .full, organization: Bool = false) async throws -> Harness {
        let h = organization ? try await Harness.organized() : try await Harness()
        if organization {
            try await h.update { $0.viewByDeviceEnabled = false; $0.viewByPlaceEnabled = false; $0.viewFavoritesEnabled = false; $0.placeNamesEnabled = false }
        }
        try h.addDrive(scope: scope)
        try await h.baseline(.googleDrive)
        return h
    }

    private func when(_ h: Harness, daysAgo: Double = 3) -> Date { h.clock.now.addingTimeInterval(-daysAgo * 86_400) }

    @Test func importedFilesReachTheDestinationAndTheJobCompletesWithOneActivityRow() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        try folder.add("a.jpg", metadata: ImportFolder.photo(at: when(h)))
        try folder.add("sub/b.jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: 4)))
        let id = try await h.startImport(folder)
        #expect(await h.drive.files.count == 2)
        #expect(try h.source(id)?.status == .completed)
        #expect(try h.importCounts(id) == [.imported: 2])
        let rows = try h.importActivity()
        #expect(rows.count == 1 && rows[0].message.contains("2 file mới"), "\(rows.map(\.message))")
        #expect(!rows[0].message.contains("Trip") && !rows[0].message.contains(".jpg"))
        await h.settle(rounds: 2)
        #expect(try h.importActivity().count == 1, "the summary is written once")
        let snapshot = await h.coordinator.currentSnapshot()
        let shown = try #require(snapshot.imports.first)
        #expect(shown.status == .completed && shown.found == 2 && shown.imported == 2 && shown.displayName == "Trip")
    }

    @Test func anImportedFileGetsTheSamePathAsAPhotosAssetWithTheSameMetadata() async throws {
        let fromPhotos = try await harness()
        let date = when(fromPhotos)
        var snapshot = fromPhotos.snapshot("0001", daysAgo: 3)
        snapshot.pixelWidth = 4000
        snapshot.pixelHeight = 3000
        await fromPhotos.add(snapshot, recordChange: true)
        await fromPhotos.settle()
        let photosPaths = await fromPhotos.backupPaths(fromPhotos.drive)

        let fromFolder = try await harness()
        let folder = try ImportFolder()
        try folder.add("IMG_0001.HEIC", metadata: ImportFolder.photo(at: date))
        try await fromFolder.startImport(folder)
        let importedPaths = await fromFolder.backupPaths(fromFolder.drive)
        #expect(photosPaths.count == 1 && photosPaths == importedPaths, "\(photosPaths) vs \(importedPaths)")
    }

    @Test func rawPlusJpegIsOneAssetWithTwoUploads() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        let date = when(h)
        try folder.add("DSC1.ARW", metadata: ImportFolder.photo(at: date, make: "SONY", model: "ILCE-7M4"))
        try folder.add("DSC1.JPG", metadata: ImportFolder.photo(at: date, make: "SONY", model: "ILCE-7M4"))
        let id = try await h.startImport(folder)
        let assets = try h.assets(of: id)
        #expect(assets.count == 1 && assets[0].category == .camera)
        #expect(try h.jobs(.done).count == 2)
        let names = await h.fileNames(h.drive)
        #expect(names.count == 2 && names.contains { $0.hasSuffix("DSC1.ARW") } && names.contains { $0.hasSuffix("DSC1.JPG") }, "\(names)")
        #expect(try h.importCounts(id) == [.imported: 2])
    }

    @Test func aLivePairIsOneAssetOnlyWhenTheContentIdentifiersMatch() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        var image = ImportFolder.photo(at: when(h))
        image.contentIdentifier = "LIVE-1"
        try folder.add("IMG_1.HEIC", metadata: image)
        try folder.add("IMG_1.MOV", metadata: FileMetadata(captureDate: when(h), duration: 2, contentIdentifier: "LIVE-1"))
        try folder.add("IMG_2.HEIC", metadata: ImportFolder.photo(at: when(h, daysAgo: 5)))
        try folder.add("IMG_2.MOV", metadata: FileMetadata(captureDate: when(h, daysAgo: 5), duration: 2))
        let id = try await h.startImport(folder)
        let assets = try h.assets(of: id)
        #expect(assets.count == 3, "one Live asset, one photo, one video")
        #expect(assets.filter { $0.mediaSubtypes.contains(.photoLive) }.count == 1)
        #expect(await h.drive.files.count == 4)
    }

    @Test func screenshotsAndPhotosWithoutACameraGoToTheirOwnBranches() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        try folder.add("Screen.png", metadata: ImportFolder.photo(at: when(h), make: nil, model: nil, screenshot: true))
        try folder.add("download.jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: 4), make: nil, model: nil))
        try folder.add("WhatsApp/chat.jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: 5)))
        try folder.add("cam.jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: 6)))
        let id = try await h.startImport(folder)
        let byName = Dictionary(uniqueKeysWithValues: try h.assets(of: id).map { ($0.placement?.nameStem ?? "", $0) })
        func category(_ suffix: String) -> AssetCategory? { byName.first { $0.key.hasSuffix(suffix) }?.value.category }
        #expect(category("Screen") == .screenshot)
        #expect(category("download") == .saved)
        #expect(category("chat") == .saved)
        #expect(category("cam") == .camera)
        let paths = await h.backupPaths(h.drive)
        #expect(paths.contains { $0.hasPrefix("Screenshots/") } && paths.contains { $0.hasPrefix("Saved/") } && paths.contains { $0.hasPrefix("Camera Uploads/") }, "\(paths)")
    }

    @Test func aNewOnlyDestinationReceivesImports() async throws {
        let h = try await harness(scope: .newOnly)
        let folder = try ImportFolder()
        try folder.add("old.jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: 900)))
        let id = try await h.startImport(folder)
        #expect(await h.drive.files.count == 1)
        #expect(try h.assets(of: id).first?.insertedAt != nil)
    }

    @Test func theSidecarCarriesTheSourceBlock() async throws {
        let h = try await harness(organization: true)
        let folder = try ImportFolder()
        try folder.add("sub/a.jpg", metadata: ImportFolder.photo(at: when(h)))
        let id = try await h.startImport(folder)
        let key = try #require(try h.assets(of: id).first?.assetKey)
        let json = try h.read { db -> String in
            let asset = try #require(try AssetRepository.fetch(db, key: key))
            let file = try #require(try SidecarFactory.build(
                db, asset: asset, destinationId: .googleDrive, type: .sidecarJson, settings: GlobalSettings(), timeZone: utc,
                nameBuilder: NameStemBuilder(timeZone: utc, utiResolver: FakeUTIResolver())))
            return String(decoding: file.data, as: UTF8.self)
        }
        #expect(json.contains("\"path\": \"sub/a.jpg\"") && json.contains("\"dateSource\": \"exif\"") && json.contains("\"name\": \"Trip\""))
        #expect(await h.sidecarItems(h.drive).count == 2)
    }

    @Test func cancelStopsIngestAndCancelsUnuploadedJobsButKeepsUploadedFiles() async throws {
        let h = try await harness()
        h.tuning.importBatchGroups = 1
        try await h.restart()
        let folder = try ImportFolder()
        for index in 0..<3 { try folder.add("p\(index).jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: Double(3 + index)))) }
        let hits = HitCounter()
        h.injector.onReach { point in
            if point == .afterImportGroupCommit, hits.next() == 2 { throw SimulatedCrash(point: point.rawValue) }
        }
        let id = try await folder.startAndRun(h)
        // Group one is uploaded; group two is ingested but the cycle stopped before exporting it.
        #expect(await h.drive.files.count == 1)
        try await h.coordinator.cancelImport(id)
        #expect(try h.source(id)?.status == .cancelled)
        #expect(try h.importCounts(id) == [.imported: 2, .cancelled: 1])
        let live = try h.assets(of: id).filter { $0.deletedAt == nil }
        #expect(live.count == 1, "the uploaded asset stays")
        #expect(try h.jobs(.pending).isEmpty)
        #expect(try h.jobs(.done).count == 1 && (try h.jobs(.cancelled).count == 1))
        h.injector.onReach(nil)
        await h.settle()
        #expect(await h.drive.files.count == 1, "nothing more is uploaded")
        let rows = try h.importActivity()
        #expect(rows.count == 1 && rows[0].message.contains("Đã huỷ"))
        try await h.coordinator.cancelImport(id)
        #expect(try h.importActivity().count == 1, "cancelling twice changes nothing")
    }

    @Test func anOfflineFolderHoldsItsJobAndPhotosKeepUploading() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        try folder.add("a.jpg", metadata: ImportFolder.photo(at: when(h)))
        let away = folder.url.deletingLastPathComponent().appendingPathComponent("Away")
        try FileManager.default.moveItem(at: folder.url, to: away)
        let id = try await h.startImport(folder)
        #expect(try h.source(id)?.status == .offline)
        await h.add(h.snapshot("p1", daysAgo: 0.1))
        await h.settle()
        #expect(await h.fakePhotos.exports(of: "p1") == 1)
        #expect(await h.drive.files.count == 1)
        try FileManager.default.moveItem(at: away, to: folder.url)
        await h.settle()
        #expect(try h.source(id)?.status == .completed)
        #expect(await h.drive.files.count == 2)
        #expect(try h.importActivity().count == 1)
    }

    @Test func aFileThatChangedAfterItWasReadIsSkippedNotUploaded() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        let file = try folder.add("a.jpg", "before", metadata: ImportFolder.photo(at: when(h)))
        h.injector.onReach { point in
            if point == .afterImportGroupCommit { try Data("after".utf8).write(to: file) }
        }
        let id = try await h.startImport(folder)
        #expect(await h.drive.files.isEmpty)
        #expect(try h.jobs(.skipped).count == 1)
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func aStartBeforeTheBaselineIsRefused() async throws {
        let h = try await Harness()
        let folder = try ImportFolder()
        await #expect(throws: EngineError.notBaselined) {
            try await h.coordinator.startFolderImport(source: folder.source(), displayName: "Trip", bookmark: nil)
        }
    }

    @Test func everyFileOfALargeTreeIsAccountedFor() async throws {
        let h = try await Harness()
        try await h.baseline()
        let folder = try ImportFolder()
        for index in 0..<900 { try folder.add("d\(index % 9)/f\(index).jpg", "content \(index)") }
        for index in 0..<60 { try folder.add("dup/copy\(index).jpg", "content \(index)") }
        for index in 0..<40 { try folder.add("d0/f\(index).AAE", "plist \(index)") }
        let started = Date()
        let id = try await h.startImport(folder, settle: 3)
        let counts = try h.importCounts(id)
        #expect(counts.values.reduce(0, +) == 1000)
        #expect(counts[.imported] == 900 && counts[.duplicate] == 60 && counts[.unsupported] == 40, "\(counts)")
        #expect(try h.source(id)?.status == .completed)
        #expect(Date().timeIntervalSince(started) < 60)
    }
}

extension ImportFolder {
    /// Starts the job and runs one cycle without settling, so a test can look at the state it leaves.
    func startAndRun(_ h: Harness) async throws -> SourceID {
        let id = try await h.coordinator.startFolderImport(source: source(), displayName: "Trip", bookmark: nil)
        await h.settle(rounds: 1)
        return id
    }
}
