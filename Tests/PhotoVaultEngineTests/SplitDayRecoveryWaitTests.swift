import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A local destination waits for Drive's recovery only while that wait can end, and never for long.
extension SplitDayRecoveryTests {
    private func loseAndReadd(_ w: World) async throws {
        try await w.h.loseDatabase(localContent: w.reader)
        try addDestinations(w.h, drive: true, local: true, localFirst: true)
    }

    private func nasActivity(_ h: Harness) throws -> [String] {
        try h.read { db in
            try Row.fetchAll(db, sql: "SELECT message FROM activity WHERE destination_id = ? ORDER BY id", arguments: [h.nasId.rawValue])
                .map { $0["message"] as String }
        }
    }

    @Test func aLocalDestinationDoesNotWaitForADriveThatIsSignedOut() async throws {
        let w = try await world(drive: true, local: true)
        try await loseAndReadd(w)
        await w.h.drive.setStatus(.paused(.signedOut))
        try w.h.updateDestination(.googleDrive) { $0.recoveryRequired = true; $0.status = .paused(.signedOut) }
        try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId, .googleDrive])
        await w.h.settle(rounds: 6)
        #expect(try w.h.destinationRecord(w.h.nasId).recoveryRequired == false, "the NAS recovers alone")
        #expect(try w.h.destinationRecord(.googleDrive).recoveryRequired, "Drive still waits for the owner")
        await w.h.add(w.h.snapshot("fresh", daysAgo: 3, location: daLat), recordChange: false)
        await w.h.settle(rounds: 6)
        let nasJobs = try w.h.jobs().filter { $0.destinationId == w.h.nasId }
        #expect(nasJobs.contains { $0.state == .done }, "the NAS receives the new photo")
    }

    @Test func aLocalDestinationDoesNotWaitForADriveAwaitingTheOwner() async throws {
        let w = try await world(drive: true, local: true)
        try await loseAndReadd(w)
        await w.h.drive.setStatus(.unavailable(.offline))
        try w.h.updateDestination(.googleDrive) { $0.recoveryRequired = true }
        try w.h.write { db in try KeyValueRepository.set(db, RecoveryService.decisionKey + DestinationID.googleDrive.rawValue, 1) }
        try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId, .googleDrive])
        await w.h.settle(rounds: 6)
        #expect(try w.h.destinationRecord(w.h.nasId).recoveryRequired == false)
    }

    @Test func aLocalDestinationWaitsForAnOfflineDriveForHalfAnHourAndShowsWhy() async throws {
        let w = try await world(drive: true, local: true)
        try await loseAndReadd(w)
        await w.h.drive.setStatus(.unavailable(.offline))
        try w.h.updateDestination(.googleDrive) { $0.recoveryRequired = true }
        try await w.h.coordinator.beginBaseline(destinations: [w.h.nasId, .googleDrive])
        await w.h.settle(rounds: 4)
        let waiting = try w.h.destinationRecord(w.h.nasId)
        #expect(waiting.recoveryRequired)
        #expect(waiting.status == .paused(.waitingForDrive), "\(waiting.status)")
        let reasons = try nasActivity(w.h).filter { $0.contains("Google Drive") }
        #expect(reasons.count == 1, "one activity row says why: \(reasons)")
        w.h.clock.advance(by: 20 * 60)
        await w.h.settle(rounds: 2)
        #expect(try w.h.destinationRecord(w.h.nasId).recoveryRequired, "still inside the half hour")
        w.h.clock.advance(by: 10 * 60)
        await w.h.settle(rounds: 6)
        #expect(try w.h.destinationRecord(w.h.nasId).recoveryRequired == false, "the NAS recovers alone after half an hour")
        #expect(try w.h.destinationRecord(.googleDrive).recoveryRequired, "Drive is still offline")
        #expect(try w.h.destinationRecord(w.h.nasId).status == .active)
    }

    /// A folder renamed on Drive before the loss (a rename another destination had not run yet, or an
    /// answer from Apple that changed since) is renamed back to the group's name, not left behind.
    @Test func aRenamedExtraFolderOnDriveIsRenamedNotEmptied() async throws {
        let w = try await world(drive: true, local: false)
        var folder = try #require(await w.h.drive.folders.first { $0.name == hanoiFolder })
        folder.name = "\(day) Hanoi City"
        await w.h.drive.put(folder)
        var before: [String: String] = [:]
        for file in await w.h.drive.files { before[file.id] = file.parentId }
        try await recoverFresh(w, drive: true, local: false)
        var moved = 0
        for file in await w.h.drive.files where before[file.id] != file.parentId { moved += 1 }
        #expect(moved == 0, "no Drive file left its folder")
        let ops = try w.h.read { db in try Row.fetchAll(db, sql: "SELECT op, COUNT(*) AS n FROM move_job GROUP BY op").map { ($0["op"] as String) + "=\($0["n"] as Int)" } }
        #expect(ops == ["renameFolder=1"], "\(ops)")
        let names = await w.h.drive.folders.map(\.name).filter { $0.hasPrefix(self.day.description + " ") }.sorted()
        #expect(names == [daLatFolder, hanoiFolder].sorted(), "\(names)")
        await expectUniqueDriveFolderNames(w)
    }
}
