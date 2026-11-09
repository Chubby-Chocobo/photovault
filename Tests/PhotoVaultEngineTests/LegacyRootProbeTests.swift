import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A root written by 0.1.0 has year folders where the current layout has day folders. It must be
/// recognised before it is offered for reuse, and recovery must refuse it.
@Suite struct LegacyRootProbeTests {
    private func probe(_ tree: [[String]: [String]]) async throws -> Bool {
        try await LegacyRootProbe.hasLegacyContent { path in tree[path] ?? [] }
    }

    @Test func yearFoldersAtTheTopOrUnderScreenshotsAndSavedMarkAnOldRoot() async throws {
        #expect(try await probe([[]: ["2025", "2026"]]))
        #expect(try await probe([[]: ["Screenshots"], ["Screenshots"]: ["2026"]]))
        #expect(try await probe([[]: ["Saved", "By device"], ["Saved"]: ["2024", "2025"]]))
    }

    @Test func theCurrentLayoutIsNotAnOldRoot() async throws {
        #expect(try await probe([:]) == false)
        #expect(try await probe([[]: ["Camera Uploads", "Screenshots", "Saved", "By device", "By place", "Favorites"],
                                 ["Screenshots"]: ["2026-11-08"], ["Saved"]: ["Unknown date"]]) == false)
        #expect(try await probe([[]: ["20260", "26", "2026-11"]]) == false)
    }

    @Test func aProbeErrorPropagates() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await LegacyRootProbe.hasLegacyContent { _ in throw Boom() } }
    }

    @Test func folderPathsOfTheOldLayoutAreRecognised() {
        #expect(LegacyRootProbe.isLegacyFolder(displayPath: "2026"))
        #expect(LegacyRootProbe.isLegacyFolder(displayPath: "Screenshots/2026"))
        #expect(LegacyRootProbe.isLegacyFolder(displayPath: "Saved/2025"))
        #expect(!LegacyRootProbe.isLegacyFolder(displayPath: "Camera Uploads"))
        #expect(!LegacyRootProbe.isLegacyFolder(displayPath: "Camera Uploads/2026-11-08"))
        #expect(!LegacyRootProbe.isLegacyFolder(displayPath: "Screenshots/2026-11-08"))
        #expect(LegacyRootProbe.isLegacyLogicalPath("camera/2026"))
        #expect(LegacyRootProbe.isLegacyLogicalPath("screenshot/2026/11"))
        #expect(!LegacyRootProbe.isLegacyLogicalPath("camera/2026-11-08"))
        #expect(!LegacyRootProbe.isLegacyLogicalPath("view/byDevice/x/2026-11-08"))
    }

    // MARK: Inventory and recovery

    private func seedDriveFolder(_ h: Harness, id: String, name: String, logical: String, parent: String = "root") async {
        await h.drive.put(.init(
            id: id, name: name, parentId: parent, kind: .folder,
            appProperties: [AppPropertyKey.schema: AppPropertyCodec.schemaVersion, AppPropertyKey.logical: logical]))
    }

    private func inventory(_ h: Harness) async throws -> RemoteInventory {
        let record = try h.destinationRecord(.googleDrive)
        return try await RemoteInventoryLoader(env: h.env, record: record, destination: h.drive).load()
    }

    @Test func driveInventoryCountsOldLayoutFolders() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try h.updateDestination(.googleDrive) { $0.config.driveRootId = "root" }
        await seedDriveFolder(h, id: "f1", name: "Camera Uploads", logical: "camera")
        await seedDriveFolder(h, id: "f2", name: "2026-11-08", logical: "camera/2026-11-08", parent: "f1")
        #expect(try await inventory(h).legacyFolders == 0)
        await seedDriveFolder(h, id: "f3", name: "2026", logical: "camera/2026")
        await seedDriveFolder(h, id: "f4", name: "11", logical: "camera/2026/11", parent: "f3")
        #expect(try await inventory(h).legacyFolders == 2)
    }

    @Test func recoveryRefusesAnOldLayoutRootAndQueuesNoMoves() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try h.updateDestination(.googleDrive) { $0.config.driveRootId = "root" }
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        await seedDriveFolder(h, id: "f3", name: "2026", logical: "camera/2026")
        await h.run()
        let outcome = try await h.coordinator.startRecovery(.googleDrive)
        #expect(outcome == .notReady(.legacyLayout))
        #expect(try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job") } == 0)
    }

    @Test func localInventoryCountsOldLayoutFolders() async throws {
        let h = try await Harness()
        try h.addNAS(scope: .full)
        let nasRecord = try h.destinationRecord(h.nasId)
        for (id, name, parent) in [("a", "2026", ""), ("b", "11", "a"), ("c", "Screenshots", ""), ("d", "2025", "c"), ("e", "Camera Uploads", "")] {
            await h.nas.put(.init(id: id, name: name, parentId: parent, kind: .folder))
        }
        let inventory = try await RemoteInventoryLoader(env: h.env, record: nasRecord, destination: h.nas).load()
        #expect(inventory.legacyFolders >= 2, "the year folders are counted, not silently ignored")
    }
}
