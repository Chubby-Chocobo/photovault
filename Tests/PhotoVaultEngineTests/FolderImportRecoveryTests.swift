import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Imports that lose their folder, files that cannot be read, and jobs that outlive their import.
@Suite struct FolderImportRecoveryTests {
    private func harness(scope: ScopeMode = .full) async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: scope)
        try await h.baseline(.googleDrive)
        return h
    }

    private func when(_ h: Harness, daysAgo: Double = 3) -> Date { h.clock.now.addingTimeInterval(-daysAgo * 86_400) }

    // MARK: Folder away mid-ingest

    @Test func aFolderThatLeavesAfterListingResumesReadingTheRest() async throws {
        let h = try await harness()
        h.tuning.importBatchGroups = 1
        try await h.restart()
        let folder = try ImportFolder()
        for (index, name) in ["a", "b", "c"].enumerated() { try folder.add("\(name).jpg", metadata: ImportFolder.photo(at: when(h).addingTimeInterval(Double(index) * 10))) }
        let away = folder.url.deletingLastPathComponent().appendingPathComponent("Away")
        let moved = HitCounter()
        h.injector.onReach { point in
            if point == .afterImportGroupCommit, moved.next() == 1 { try FileManager.default.moveItem(at: folder.url, to: away) }
        }
        let id = try await h.startImport(folder)
        #expect(try h.source(id)?.status == .offline)
        try FileManager.default.moveItem(at: away, to: folder.url)
        await h.settle(rounds: 10)
        #expect(try h.source(id)?.status == .completed)
        #expect(try h.importCounts(id) == [.imported: 3])
        #expect(await h.drive.files.count == 3)
    }

    // MARK: After relaunch

    @Test func aFinishedImportKeepsItsFilesReadableAfterRelaunchForADestinationAddedLater() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        try folder.add("a.jpg", metadata: ImportFolder.photo(at: when(h)))
        let id = try await h.startImport(folder)
        #expect(try h.source(id)?.status == .completed)
        try h.addNAS(scope: .full)
        try await h.reopenSources([folder])
        try await h.coordinator.destinationAdded(h.nasId)
        for _ in 0..<4 { await h.run(); h.clock.advance(by: 3600) }
        #expect(await h.nas.files.count == 1, "the new destination receives the imported file")
    }

    @Test func aFinishedImportWhoseFolderIsGoneSkipsItsJobsAndSyncStillCounts() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        try folder.add("a.jpg", metadata: ImportFolder.photo(at: when(h)))
        let id = try await h.startImport(folder)
        try h.addNAS(scope: .full)
        try FileManager.default.removeItem(at: folder.url)
        try await h.reopenSources([folder])
        try await h.coordinator.destinationAdded(h.nasId)
        for _ in 0..<4 { await h.run(); h.clock.advance(by: 3600) }
        let skipped = try h.jobs(.skipped, destination: h.nasId)
        #expect(skipped.count == 1 && skipped[0].stateReason == .resourceMissing)
        #expect(try h.source(id)?.status == .completed, "a finished job does not reopen")
        #expect(try h.lastSuccess() != nil)
    }

    @Test func anImportWhoseAdapterIsNotRegisteredIsSkippedOnceFinished() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        try folder.add("a.jpg", metadata: ImportFolder.photo(at: when(h)))
        _ = try await h.startImport(folder)
        try h.addNAS(scope: .full)
        try await h.reopenSources([])
        try await h.coordinator.destinationAdded(h.nasId)
        for _ in 0..<3 { await h.run(); h.clock.advance(by: 3600) }
        #expect(try h.jobs(.skipped, destination: h.nasId).count == 1)
    }

    @Test func exportsHeldBecauseTheirOpenImportIsOfflineAreNotASyncFailure() async throws {
        let h = try await harness()
        let source = FakeContentSource()
        source.setOnline(false)
        _ = try await h.seedImported("held", source: source, status: .importing)
        for _ in 0..<3 { await h.run(); h.clock.advance(by: 120) }
        #expect(try h.read { try SourceRepository.fetch($0, id: source.id) }?.status == .offline)
        #expect(try h.lastSuccess() != nil, "a folder that is away is not a stalled sync")
        let errors = try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM resource WHERE last_error IS NOT NULL") }
        #expect(errors == 0)
    }

    // MARK: Unreadable file

    @Test func oneUnreadableFileFailsOnlyItselfAndTheCycleDrains() async throws {
        let h = try await Harness { $0.maxCycleIterations = 40 }
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let folder = try ImportFolder()
        try folder.add("bad.jpg", metadata: ImportFolder.photo(at: when(h)))
        try folder.add("good.jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: 4)))
        let id = try await h.coordinator.startFolderImport(source: BadFileSource(inner: folder.source()), displayName: "Trip", bookmark: nil)
        let outcome = await h.coordinator.run(trigger: .manual)
        guard case .completed(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.drained && report.rounds < 20, "rounds \(report.rounds)")
        await h.settle(rounds: 2)
        #expect(try h.source(id)?.status == .completed)
        #expect(try h.importCounts(id) == [.imported: 1, .failed: 1])
    }

    @Test func aFolderThatFlapsDoesNotKeepTheCycleBusy() async throws {
        let h = try await Harness { $0.maxCycleIterations = 60 }
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let folder = try ImportFolder()
        try folder.add("a.jpg", metadata: ImportFolder.photo(at: when(h)))
        _ = try await h.coordinator.startFolderImport(source: FlappingSource(inner: folder.source()), displayName: "Trip", bookmark: nil)
        let outcome = await h.coordinator.run(trigger: .manual)
        guard case .completed(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.drained && report.rounds < 10, "rounds \(report.rounds)")
    }

    // MARK: Changed companions

    @Test func aPairedFileThatChangedAfterItWasReadIsSkipped() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        let date = when(h)
        try folder.add("DSC1.ARW", metadata: ImportFolder.photo(at: date, make: "SONY", model: "A7"))
        let jpg = try folder.add("DSC1.JPG", "before", metadata: ImportFolder.photo(at: date, make: "SONY", model: "A7"))
        h.injector.onReach { point in
            if point == .afterImportGroupCommit { try Data("after".utf8).write(to: jpg) }
        }
        _ = try await h.startImport(folder)
        let names = await h.fileNames(h.drive)
        #expect(names.count == 1 && names[0].hasSuffix(".ARW"), "\(names)")
        #expect(try h.jobs(.skipped).count == 1)
    }
}
