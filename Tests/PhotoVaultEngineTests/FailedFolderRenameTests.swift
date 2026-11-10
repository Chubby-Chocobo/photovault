import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A folder rename that fails for good must not leave the folder with a stale name: the name the day has now
/// is queued once, from the name on disk.
@Suite struct FailedFolderRenameTests {
    private let day = organizationDay
    private var main: String { "camera/\(day)" }

    private func harness() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
        }
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        for index in 0..<3 { await h.add(h.snapshot("h\(index)", daysAgo: 3, location: hanoi), recordChange: false) }
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        return h
    }

    private func destination(_ h: Harness, _ id: DestinationID) -> FakeDestination { id == h.nasId ? h.nas : h.drive }

    private func folderNames(_ fake: FakeDestination) async -> Set<String> {
        Set(await fake.folders.map(\.name).filter { $0.hasPrefix(day.description) })
    }

    private func onDisk(_ h: Harness, _ id: DestinationID) throws -> String {
        try #require(try h.read { db in try RemoteFolderRepository.fetch(db, destinationId: id, logicalPath: self.main)?.displayName })
    }

    /// The day is now called `current`; a rename to `failedTarget` and one queued behind it (for the name the
    /// first would produce) are open.
    private func queueStale(_ h: Harness, _ id: DestinationID, failedTarget: String, current: String) throws {
        let old = try onDisk(h, id)
        try h.write { db in
            let now = h.clock.now
            try DayStatRepository.setPlace(db, day: self.day, state: .named, key: "VN|Test", name: current)
            try MoveJobRepository.insert(db, MoveJob(
                destinationId: id, operation: .renameFolder, subject: self.main, fromValue: old, toValue: "\(self.day) \(failedTarget)", createdAt: now))
            try MoveJobRepository.insert(db, MoveJob(
                destinationId: id, operation: .renameFolder, subject: self.main,
                fromValue: "\(self.day) \(failedTarget)", toValue: "\(self.day) \(current)", createdAt: now))
        }
    }

    @Test(arguments: [false, true])
    func aRenameQueuedBehindOneThatFailedForGoodStillEndsWithTheCurrentName(onNAS: Bool) async throws {
        let h = try await harness()
        let id = onNAS ? h.nasId : DestinationID.googleDrive
        let fake = destination(h, id)
        try queueStale(h, id, failedTarget: "Bravo", current: "Charlie")
        await fake.failNext(.rename, with: .itemRejected(reason: "exists"), times: MoveJob.maxAttempts + 1)
        await h.settle(rounds: 16)
        let names = await folderNames(fake)
        #expect(names == ["\(day) Charlie"], "\(names)")
        #expect(try onDisk(h, id) == "\(day) Charlie")
        #expect(try h.moveJobs(.pending, destination: id).isEmpty)
        #expect(try h.moveJobs(.failed, destination: id).count == 1, "the failed rename stays as it was")
    }

    @Test func aRenameThatFailsAgainIsNotQueuedForever() async throws {
        let h = try await harness()
        let old = try onDisk(h, h.nasId)
        try queueStale(h, h.nasId, failedTarget: "Bravo", current: "Charlie")
        await h.nas.failNext(.rename, with: .itemRejected(reason: "exists"), times: 10_000)
        await h.settle(rounds: 40)
        #expect(try h.moveJobs(.failed, destination: h.nasId).count == 2, "one fresh attempt, not a loop")
        #expect(try h.moveJobs(.pending, destination: h.nasId).isEmpty)
        #expect(try onDisk(h, h.nasId) == old)
    }

    private func renameJobs(_ h: Harness, _ id: DestinationID) throws -> Int {
        try h.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE destination_id = ? AND op = 'renameFolder'", arguments: [id.rawValue]) ?? 0
        }
    }

    /// A name another folder carries is worded as such; any other failure is not blamed on a name clash.
    @Test(arguments: [DestinationError.foreignFile, .alreadyExists(remoteId: "x"), .itemRejected(reason: "permission")])
    func aFailedRenameToTheNameTheDayStillHasIsNotRetriedAndTheFolderKeepsItsName(_ error: DestinationError) async throws {
        let h = try await harness()
        let old = try onDisk(h, h.nasId)
        try h.write { db in
            try DayStatRepository.setPlace(db, day: self.day, state: .named, key: "VN|Test", name: "Bravo")
            try MoveJobRepository.insert(db, MoveJob(
                destinationId: h.nasId, operation: .renameFolder, subject: self.main, fromValue: old, toValue: "\(self.day) Bravo", createdAt: h.clock.now))
        }
        let before = try h.read { db in try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM activity") ?? 0 }
        await h.nas.failNext(.rename, with: error, times: 10_000)
        await h.settle(rounds: 30)
        #expect(try h.moveJobs(.failed, destination: h.nasId).count == 1)
        #expect(try h.moveJobs(.pending, destination: h.nasId).isEmpty)
        #expect(try onDisk(h, h.nasId) == old, "never merged into or over another folder")
        let messages = try h.read { db in try String.fetchAll(db, sql: "SELECT message FROM activity WHERE destination_id = ? AND id > ?", arguments: [h.nasId.rawValue, before]) }
        let kept = messages.filter { $0.contains("giữ tên hiện tại") || $0.contains("keeps its current name") }
        #expect(kept.count == 1, "the owner can see that the name stayed: \(messages)")
        let clash = kept.contains { $0.contains("trùng tên") || $0.contains("already has a folder") }
        if case .itemRejected = error { #expect(!clash, "not blamed on a name clash") } else { #expect(clash) }
        #expect(!messages.contains { $0.contains("Bravo") || $0.contains(old) || $0.contains(day.description) }, "no folder name in the activity text")
    }

    @Test func aRenameThatStartsFromTheNameOnDiskIsNotDuplicatedWhenAnotherOneFailsForGood() async throws {
        let h = try await harness()
        let baseline = try renameJobs(h, h.nasId)
        let old = try onDisk(h, h.nasId)
        try h.write { db in
            let now = h.clock.now
            try DayStatRepository.setPlace(db, day: self.day, state: .named, key: "VN|Test", name: "Charlie")
            for target in ["Bravo", "Charlie"] {
                try MoveJobRepository.insert(db, MoveJob(
                    destinationId: h.nasId, operation: .renameFolder, subject: self.main, fromValue: old, toValue: "\(self.day) \(target)", createdAt: now))
            }
        }
        await h.nas.failNext(.rename, with: .itemRejected(reason: "exists"), times: MoveJob.maxAttempts + 1)
        await h.settle(rounds: 16)
        let rows = try h.read { db in try Row.fetchAll(db, sql: "SELECT from_value, to_value, state FROM move_job WHERE op = 'renameFolder'") }
        #expect(try renameJobs(h, h.nasId) - baseline == 2, "\(rows) the open rename needs no second one beside it")
        #expect(try onDisk(h, h.nasId) == "\(day) Charlie")
    }

    @Test func aFolderThatAlreadyHasTheDaysNameIsNotRenamedAfterAFailedRename() async throws {
        let h = try await harness()
        let baseline = try renameJobs(h, h.nasId)
        let old = try onDisk(h, h.nasId)
        try h.write { db in
            try MoveJobRepository.insert(db, MoveJob(
                destinationId: h.nasId, operation: .renameFolder, subject: self.main, fromValue: old, toValue: "\(self.day) Bravo", createdAt: h.clock.now))
        }
        await h.nas.failNext(.rename, with: .itemRejected(reason: "exists"), times: MoveJob.maxAttempts + 1)
        await h.settle(rounds: 16)
        let rows = try h.read { db in try Row.fetchAll(db, sql: "SELECT from_value, to_value, state FROM move_job WHERE op = 'renameFolder'") }
        #expect(try renameJobs(h, h.nasId) - baseline == 1, "\(rows) the name on disk is already the day's name")
        #expect(try onDisk(h, h.nasId) == old)
    }
}
