import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A local destination recovered alone guesses its slots; when Drive is recovered later the database follows
/// Drive: by what each folder holds first, by name after that. Nothing moves at Drive and no folder is mislabelled.
extension SplitDayRecoveryTests {
    private func driveFileParents(_ h: Harness) async -> [String: String] {
        var result: [String: String] = [:]
        for file in await h.drive.files { result[file.id] = file.parentId }
        return result
    }

    private func driveFilesMoved(_ h: Harness, since before: [String: String]) async -> Int {
        var moved = 0
        for file in await h.drive.files where before[file.id] != file.parentId { moved += 1 }
        return moved
    }

    /// "<folder>: d=<Đà Lạt files> h=<Hà Nội files>" per camera folder at the NAS.
    private func nasContents(_ root: URL) -> [String] {
        var per: [String: (d: Int, h: Int)] = [:]
        for key in treeListing(root).keys where key.hasPrefix("Camera Uploads/") {
            let parts = key.split(separator: "/")
            guard parts.count >= 3 else { continue }
            var entry = per[String(parts[1])] ?? (0, 0)
            if parts.last!.contains("_h") { entry.h += 1 } else { entry.d += 1 }
            per[String(parts[1])] = entry
        }
        return per.sorted { $0.key < $1.key }.map { "\($0.key): d=\($0.value.d) h=\($0.value.h)" }
    }

    private func recoverNASAloneThenAddDrive(_ w: World, pauseNAS: Bool = false) async throws {
        try await w.h.loseDatabase(localContent: w.reader)
        try w.h.addNAS(scope: .full)
        if pauseNAS { try w.h.updateDestination(w.h.nasId) { $0.recoveryRequired = true; $0.status = .paused(.userPaused) } }
        try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId])
        await w.h.settle(rounds: 10)
        try w.h.addDrive(scope: .full)
        try await w.h.coordinator.beginBaseline(destinations: [.googleDrive])
        await w.h.settle(rounds: 10)
    }

    @Test func aRenamePendingAtTheNASFollowsItsFolderThroughTheRebind() async throws {
        let w = try await world(drive: true, local: true)
        let root = try #require(w.root)
        let base = root.appendingPathComponent("Camera Uploads")
        try FileManager.default.moveItem(at: base.appendingPathComponent(hanoiFolder), to: base.appendingPathComponent("\(day) Hanoi City"))
        let before = await driveFileParents(w.h)
        try await w.h.loseDatabase(localContent: w.reader)
        try w.h.addNAS(scope: .full)
        try w.h.updateDestination(w.h.nasId) { $0.recoveryRequired = true; $0.status = .paused(.userPaused) }
        try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId])
        await w.h.settle(rounds: 10)
        let open = try w.h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE op = 'renameFolder' AND state IN ('pending', 'inProgress')") ?? 0 }
        #expect(open >= 1, "the rename is still pending while the NAS is paused")
        try w.h.addDrive(scope: .full)
        try await w.h.coordinator.beginBaseline(destinations: [.googleDrive])
        await w.h.settle(rounds: 10)
        try w.h.updateDestination(w.h.nasId) { $0.status = .active }
        await w.h.settle(rounds: 10)
        #expect(await driveFilesMoved(w.h, since: before) == 0)
        #expect(nasContents(root) == ["\(hanoiFolder): d=0 h=9", "\(daLatFolder): d=30 h=0"], "\(nasContents(root))")
    }

    @Test func aRenamedExtraFolderOnDriveKeepsItsFilesWhenTheNASWasRecoveredFirst() async throws {
        let w = try await world(drive: true, local: true)
        var folder = try #require(await w.h.drive.folders.first { $0.name == hanoiFolder })
        folder.name = "\(day) Hanoi City"
        await w.h.drive.put(folder)
        let before = await driveFileParents(w.h)
        try await recoverNASAloneThenAddDrive(w)
        #expect(await driveFilesMoved(w.h, since: before) == 0)
        let names = await w.h.drive.folders.map(\.name).filter { $0.hasPrefix(day.description + " ") }.sorted()
        #expect(names == [daLatFolder, hanoiFolder].sorted(), "\(names)")
        await expectUniqueDriveFolderNames(w)
    }

    @Test func aRenamedMainFolderOnDriveKeepsItsFilesWhenTheNASWasRecoveredFirst() async throws {
        let w = try await world(drive: true, local: true)
        var folder = try #require(await w.h.drive.folders.first { $0.name == daLatFolder })
        folder.name = "\(day) Dalat"
        await w.h.drive.put(folder)
        let before = await driveFileParents(w.h)
        try await recoverNASAloneThenAddDrive(w)
        #expect(await driveFilesMoved(w.h, since: before) == 0)
        let names = await w.h.drive.folders.map(\.name).filter { $0.hasPrefix(day.description + " ") }.sorted()
        #expect(names == [daLatFolder, hanoiFolder].sorted(), "\(names)")
        await expectUniqueDriveFolderNames(w)
    }

    @Test func nothingIsReboundWhileDrivesRecoveryAsksTheOwner() async throws {
        let w = try await world(drive: true, local: true)
        try await w.h.loseDatabase(localContent: w.reader)
        try w.h.addNAS(scope: .full)
        try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId])
        await w.h.settle(rounds: 10)
        let rows = { try w.h.folderRows(w.h.nasId).filter { $0.logicalPath.hasPrefix("camera/") }.map { "\($0.logicalPath)=\($0.displayName)" } }
        let before = try rows()
        let parent = try #require(await w.h.drive.folders.first { $0.name == daLatFolder })
        for i in 0..<60 {
            await w.h.drive.put(FakeDestination.Item(id: "junk\(i)", name: "junk\(i).bin", parentId: parent.id, kind: .file, appProperties: parent.appProperties))
        }
        try w.h.addDrive(scope: .full)
        try await w.h.coordinator.beginBaseline(destinations: [.googleDrive])
        await w.h.settle(rounds: 6)
        #expect(try w.h.destinationRecord(.googleDrive).recoveryRequired, "Drive waits for the owner")
        #expect(try rows() == before, "the NAS rows are as they were")
        #expect(try !w.h.read { db in try ProvisionalSlots.days(db) }.isEmpty, "the days stay provisional")
    }

    @Test func aFolderGuessedAfterDriveWasRecoveredIsNotProvisional() async throws {
        let w = try await world(drive: true, local: true, hanoiCount: 0)
        let root = try #require(w.root)
        let base = root.appendingPathComponent("Camera Uploads")
        try FileManager.default.moveItem(at: base.appendingPathComponent(daLatFolder), to: base.appendingPathComponent("\(day) Dalat"))
        try await recoverFresh(w, drive: true, local: true)
        #expect(try w.h.destinationRecord(w.h.nasId).recoveryRequired == false)
        #expect(try w.h.read { db in try ProvisionalSlots.days(db) }.isEmpty)
    }

    @Test func restoringTheTimezoneClearsTheProvisionalDays() async throws {
        let w = try await world(drive: false, local: true)
        try w.h.write { db in try ProvisionalSlots.mark(db, [self.day]) }
        try await RecoveryService.clearDayState(env: w.h.env)
        #expect(try w.h.read { db in try ProvisionalSlots.days(db) }.isEmpty)
    }

    @Test func aRowOutsideTheRebindOnATargetPathLeavesTheDayAlone() throws {
        let store = try Store.inMemory()
        let path = DynamicLayout.slotLogicalPath(day: day, slot: "p0123456789ab")
        try store.write { db in
            try db.execute(sql: "INSERT INTO destination (id, kind, display_name, status, status_since, scope_mode, rules_json, config_json, recovery_required, created_at) VALUES ('nas', 'localFolder', 'NAS', 'active', 0, 'full', '{}', '{}', 0, 0)")
            try db.execute(sql: "INSERT INTO day_stat (day, count, promoted) VALUES (?, 1, 1)", arguments: [self.day.description])
            try DayStatRepository.setPlace(db, day: self.day, state: .named, key: "K", name: "Hà Nội")
            try db.execute(sql: "INSERT INTO remote_folder (destination_id, logical_path, remote_id, display_name, created) VALUES ('nas', ?, 'x', 'orphan', 1)", arguments: [path])
            try ProvisionalSlots.mark(db, [self.day])
        }
        let truth = [RemoteFolderEntry(logicalPath: path, remoteId: "d1", displayName: "\(day) Hà Nội", day: day, slot: "p0123456789ab", placeName: "Hà Nội")]
        let result = try store.write { db in try ProvisionalSlots.resolve(db, truth: truth, days: [self.day], files: []) }
        #expect(result.skipped == 1)
        #expect(try store.read { db in try ProvisionalSlots.days(db) } == [day])
        #expect(try store.read { db in try DayStatRepository.fetch(db, day: self.day)?.placeName } == "Hà Nội")
    }

    @Test func aRenameQueuedForAnotherNameThanTheFolderCarriesIsDiscarded() async throws {
        let w = try await world(drive: true, local: false)
        let before = await w.h.drive.folders.map(\.name).sorted()
        try w.h.write { db in
            try MoveJobRepository.insert(db, MoveJob(
                destinationId: .googleDrive, operation: .renameFolder, subject: "camera/\(self.day)",
                fromValue: "\(self.day) Somewhere Else", toValue: "\(self.day) Wrong", createdAt: Date()))
        }
        await w.h.settle(rounds: 3)
        #expect(await w.h.drive.folders.map(\.name).sorted() == before, "the folder keeps its name")
        let open = try w.h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE state IN ('pending', 'inProgress', 'failed')") ?? 0 }
        #expect(open == 0, "the stale job is gone")
    }
}
