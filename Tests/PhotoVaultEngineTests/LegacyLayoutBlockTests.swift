import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A database written by 0.1.0 keeps `camera/YYYY/MM` parents. The new layout does not migrate
/// them, so the engine stays still instead of splitting sidecars from originals.
@Suite struct LegacyLayoutBlockTests {
    /// A drive with one uploaded photo whose job sits under the old `YYYY/MM` path, as 0.1.0 stored it.
    private func legacyHarness() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false; $0.viewByPlaceEnabled = false; $0.viewFavoritesEnabled = false; $0.placeNamesEnabled = false
        }
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        try h.write { db in
            let parent = try String.fetchOne(db, sql: "SELECT remote_logical_parent FROM upload_job LIMIT 1")!
            let rid = try String.fetchOne(db, sql: "SELECT remote_id FROM remote_folder WHERE logical_path = ?", arguments: [parent])
            try db.execute(sql: "INSERT INTO remote_folder (destination_id, logical_path, remote_id, display_name, created) VALUES ('gdrive', 'camera/2026/10', ?, '10', 1)", arguments: [rid])
            try db.execute(sql: "UPDATE upload_job SET remote_logical_parent = 'camera/2026/10'")
            try db.execute(sql: "DELETE FROM kv WHERE key = 'legacy_layout'")
        }
        try await h.restart()
        return h
    }

    private func moveCount(_ h: Harness) throws -> Int {
        try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job") ?? 0 }
    }

    @Test func oldLayoutDatabaseDoesNothingAndReportsTheBlock() async throws {
        let h = try await legacyHarness()
        let before = try h.jobs().map { "\($0.resType) \($0.remoteLogicalParent ?? "-")" }
        let filesBefore = await h.fileNames(h.drive)
        var favorite = h.snapshot("a", daysAgo: 3)
        favorite.isFavorite = true
        await h.fakePhotos.update(favorite)
        await h.add(h.snapshot("b", daysAgo: 2))

        let outcome = await h.run()
        #expect(outcome == .blocked(.legacyLayout))
        await h.settle()
        #expect(try moveCount(h) == 0)
        #expect(try h.jobs().map { "\($0.resType) \($0.remoteLogicalParent ?? "-")" } == before)
        #expect(await h.fileNames(h.drive) == filesBefore)
        #expect(try h.assetCount() == 1)
        #expect(await h.coordinator.currentSnapshot().overall == .legacyLayout)
        // Persisted once; a second run stays blocked.
        #expect(try h.read { db in try KeyValueRepository.string(db, KeyValueRepository.Key.legacyLayout) } == "1")
        #expect(await h.run() == .blocked(.legacyLayout))
    }

    @Test func blockSurvivesARestartAndSkipsStartupRecoveryAndCommands() async throws {
        let h = try await legacyHarness()
        _ = await h.run()
        try await h.restart()
        _ = try await h.coordinator.start()
        await #expect(throws: EngineError.legacyLayout) { try await h.coordinator.settingsChanged() }
        // Root commands could create, untrash or adopt Drive folders: they stop too.
        await #expect(throws: EngineError.legacyLayout) { try await h.coordinator.untrashAppItems(.googleDrive) }
        await #expect(throws: EngineError.legacyLayout) {
            try await h.coordinator.resolveRootProblem(.googleDrive, choice: .uploadToNewRoot(name: "PhotoVault"))
        }
        await #expect(throws: EngineError.legacyLayout) { try await h.coordinator.adoptExistingRoot(.googleDrive, rootId: "r") }
        await #expect(throws: EngineError.legacyLayout) {
            try await h.coordinator.changeDriveRoot(.googleDrive, rootId: "r", rootName: "PhotoVault", rootHasContent: false)
        }
        #expect(try moveCount(h) == 0)
        #expect(await h.run() == .blocked(.legacyLayout))
        #expect(await h.coordinator.currentSnapshot().overall == .legacyLayout)
    }

    @Test func freshDatabaseAfterResetSyncs() async throws {
        let h = try await Harness.organized()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        let outcome = await h.run()
        guard case .completed(let report) = outcome else { Issue.record("expected a completed cycle, got \(outcome)"); return }
        #expect(report.uploaded > 0)
        #expect(try h.read { db in try KeyValueRepository.string(db, KeyValueRepository.Key.legacyLayout) } == "0")
        #expect(await h.coordinator.currentSnapshot().overall != .legacyLayout)
    }

    @Test func detectsOnlyYearFoldersUnderBranches() throws {
        let store = try Store.inMemory()
        func check(_ parents: [String]) throws -> Bool {
            try store.write { db in
                try db.execute(sql: "DELETE FROM remote_folder")
                for (index, path) in parents.enumerated() {
                    try db.execute(sql: "INSERT INTO remote_folder (destination_id, logical_path, remote_id, display_name, created) VALUES ('gdrive', ?, ?, 'x', 1)", arguments: [path, "r\(index)"])
                }
                return try LegacyLayout.isPresent(db)
            }
        }
        #expect(try check(["camera/2026", "camera/2026/10"]))
        #expect(try check(["screenshot/2025/01"]))
        #expect(try check(["saved/2024"]))
        #expect(try check(["camera", "camera/2026-10-12", "camera/unknown", "screenshot/2026-10-12", "view/byDevice/x/2026-10-12"]) == false)
        #expect(try check([]) == false)
    }
}
