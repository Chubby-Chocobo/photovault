import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Reading the Drive sidecars back during recovery survives throttling, failures and restarts without
/// starting over or writing anything it does not have to.
@Suite struct RecoveryReadBackTests {
    private func life(assets: Int = 5) async throws -> Harness {
        let h = try await Harness.organized()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        try h.addDrive(scope: .full)
        await h.addCameraAssets(assets, prefix: "d", daysAgo: 3, recordChange: false, location: daLat)
        await h.add(h.snapshot("other", daysAgo: 40), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)
        return h
    }

    private func writes(_ h: Harness) async -> Int {
        await h.drive.operationLog.filter { $0 == .upload || $0 == .replace }.count
    }

    private func reads(_ h: Harness) async -> Int { await h.count(of: .read, on: h.drive) }

    private func recover(_ h: Harness, rounds: Int = 8) async throws {
        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle(rounds: rounds)
    }

    private func recovered(_ h: Harness) throws -> Bool {
        let record = try h.destinationRecord(.googleDrive)
        return record.status == .active && !record.recoveryRequired
    }

    @Test func everyThirdReadFailingStillFinishesWithBoundedReadsAndNoWrites() async throws {
        let h = try await life()
        let before = await writes(h)
        await h.drive.failEvery(.read, n: 3, with: .server(status: 503))
        try await recover(h)
        #expect(try recovered(h))
        #expect(await writes(h) == before, "every sidecar was read after a retry")
        let total = await reads(h)
        #expect(total <= 6 * 2, "a failed read is retried for that sidecar, not the whole pass: \(total)")
    }

    @Test func aRestartAfterOfflineDoesNotReadTheSidecarsAgain() async throws {
        let h = try await life()
        let before = await writes(h)
        await h.drive.failEvery(.read, n: 4, with: .offline)
        try await recover(h)
        #expect(try recovered(h))
        #expect(await writes(h) == before)
        // Six sidecars: three read, the fourth call goes offline, the rest follow without reading the first three again.
        let total = await reads(h)
        #expect(total == 7, "\(total)")
    }

    @Test func aSidecarThatFailsForGoodIsSkippedAndWrittenOnce() async throws {
        let h = try await life()
        let before = await writes(h)
        let victim = try #require(await h.drive.files.first { $0.name.hasSuffix("IMG_d2.json") })
        await h.drive.failReads(of: victim.id, with: .server(status: 503))
        try await recover(h)
        #expect(try recovered(h))
        let delta = await writes(h) - before
        #expect(delta >= 1 && delta <= 2, "only that asset's sidecars, once: \(delta)")
        await h.settle(rounds: 4)
        #expect(await writes(h) - before == delta)
    }

    @Test func offlineDuringReadBackStopsRecoveryCleanlyAndItFinishesLater() async throws {
        let h = try await life()
        let before = await writes(h)
        await h.drive.failEvery(.read, n: 1, with: .offline)
        try await recover(h, rounds: 4)
        #expect(try !recovered(h))
        #expect(await writes(h) == before, "nothing is written while the destination cannot be read")
        await h.drive.clearPeriodicFailures()
        await h.settle(rounds: 8)
        #expect(try recovered(h))
        #expect(await writes(h) == before)
    }

    @Test func aRunOfSidecarsGivenUpOnStopsRecoveryInsteadOfSkippingTheLibrary() async throws {
        let h = try await life(assets: 14)
        let before = await writes(h)
        await h.drive.failEvery(.read, n: 1, with: .server(status: 503))
        try await recover(h, rounds: 3)
        #expect(await writes(h) == before, "no sidecar is written while reads keep failing")
        let total = await reads(h)
        #expect(total <= (RemoteInventoryLoader.consecutiveGiveUps + 1) * RemoteInventoryLoader.readAttempts * 3, "\(total)")
        await h.drive.clearPeriodicFailures()
        await h.settle(rounds: 8)
        #expect(try recovered(h))
        #expect(await writes(h) == before)
    }
}
