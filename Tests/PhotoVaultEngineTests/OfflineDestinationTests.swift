import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct OfflineDestinationTests {
    /// T26: the NAS is away for three days. Drive keeps receiving, staging never grows, and the
    /// NAS catches up afterwards at the re-export rate limit.
    @Test func t26OfflineNasForThreeDaysThenCatchesUpWithRateLimit() async throws {
        let h = try await Harness()
        try await h.update { $0.backfillBytesPerHour = 1_000 }
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        try await h.baseline(.googleDrive, h.nasId)
        func photo(_ id: String) async {
            await h.fakePhotos.add(h.snapshot(id, daysAgo: 0), resources: [.photo: Data(repeating: 9, count: 400)], header: camera)
        }
        await photo("seed")
        await h.run()
        #expect(await h.drive.files.count == 1)
        #expect(await h.nas.files.count == 1)

        await h.nas.setStatus(.unavailable(.offline))
        var maxStaged = 0
        for day in 0..<3 {
            for hour in 0..<4 {
                h.clock.advance(by: 6 * 3600)
                await photo("d\(day)h\(hour)")
                await h.run()
                maxStaged = max(maxStaged, h.stagingFiles().count)
            }
        }
        #expect(await h.drive.files.count == 13, "Drive kept receiving every photo")
        #expect(await h.nas.files.count == 1)
        #expect(maxStaged == 0, "staging never holds files for an offline destination")
        #expect(try h.jobs(.pending, destination: h.nasId).count == 12)
        let status = try h.read { db in try DestinationRepository.fetch(db, id: h.nasId)?.status }
        #expect(status == .unavailable(.offline))

        await h.nas.setStatus(.active)
        await h.run()
        let firstHour = await h.nas.files.count
        #expect(firstHour == 3, "seed plus two re-exports admitted by the bucket: \(firstHour)")
        for _ in 0..<8 {
            h.clock.advance(by: 3600)
            await h.run()
        }
        #expect(await h.nas.files.count == 13)
        #expect(await h.drive.files.count == 13)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        #expect(h.stagingFiles().isEmpty)
        #expect(await h.nas.contractViolations.isEmpty)
    }

    @Test func destinationRemovalDropsItsStateAndLeavesTheOthers() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("x"), recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)
        await h.run()
        try h.write { db in try DestinationRepository.remove(db, id: h.nasId) }
        await h.coordinator.destinationRemoved(h.nasId)
        #expect(try h.jobs().allSatisfy { $0.destinationId == .googleDrive })
        #expect(await h.env.destinations.ids == [.googleDrive, h.nasId].filter { $0 == .googleDrive })
        #expect(await h.nas.files.count == 1, "nothing is deleted at the destination (FR-71)")
    }

    @Test func resetDestinationRecreatesJobsFromTheDatabaseOnceRecoveryIsCleared() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("x"), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        try h.write { db in try DestinationRepository.resetState(db, id: .googleDrive) }
        #expect(try h.jobs().isEmpty)
        // While recovery is required no job is created and nothing uploads.
        try await h.coordinator.destinationAdded(.googleDrive)
        #expect(try h.jobs().isEmpty)
        try h.write { db in try DestinationRepository.setRecoveryRequired(db, id: .googleDrive, false) }
        try await h.coordinator.destinationAdded(.googleDrive)
        #expect(try h.jobs(.pending).count == 1)
        let job = try #require(try h.jobs().first)
        #expect(job.origin == .destinationBackfill)
    }

    @Test func recoveringDestinationReceivesNothing() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("x"), recordChange: false)
        try await h.baseline(.googleDrive)
        try h.write { db in try DestinationRepository.setStatus(db, id: .googleDrive, status: .paused(.recovering), now: h.clock.now) }
        await h.run()
        #expect(try h.jobs().isEmpty)
        #expect(await h.drive.files.isEmpty)
    }
}
