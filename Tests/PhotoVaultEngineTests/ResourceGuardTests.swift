import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

private let GiB = GlobalSettings.GiB

@Suite struct ResourceGuardTests {
    private func makeGuard(_ h: Harness) -> ResourceGuard {
        ResourceGuard(env: h.env, staging: StagingManager(env: h.env))
    }

    private func isGranted(_ admission: Admission) -> Bool {
        if case .granted = admission { return true }
        return false
    }

    private func denial(_ admission: Admission) -> AdmissionDenial? {
        if case .denied(let reason) = admission { return reason }
        return nil
    }

    @Test func grantsWhenDiskIsHealthy() async throws {
        let h = try await Harness()
        let guardActor = makeGuard(h)
        #expect(isGranted(await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil)))
        #expect(isGranted(await guardActor.admit(rateLimited: true, estimatedBytes: 1, sizeLimit: nil)))
        #expect(await guardActor.activeCount == 2)
    }

    @Test func criticalWatermarkStopsEverythingAndCancelsRunningExports() async throws {
        let h = try await Harness()
        let guardActor = makeGuard(h)
        guard case .granted(let running) = await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil) else {
            Issue.record("expected a permit")
            return
        }
        h.disk.set(available: 4 * GiB)
        #expect(await guardActor.enforce())
        #expect(running.control.isCancelled)
        #expect(running.reason == .disk)
        #expect(denial(await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil)) == .stopAll(.criticalDisk))
        #expect(denial(await guardActor.admit(rateLimited: true, estimatedBytes: 1, sizeLimit: nil)) == .stopAll(.criticalDisk))
    }

    @Test func theTimeTheDiskFirstFilledIsKeptUntilItHasRoomAgain() async throws {
        let h = try await Harness()
        let guardActor = makeGuard(h)
        let key = KeyValueRepository.Key.macDiskFullSince
        h.disk.set(available: 4 * GiB)
        await guardActor.enforce()
        let first = try h.read { try KeyValueRepository.date($0, key) }
        #expect(first != nil)
        h.clock.advance(by: 3600)
        await guardActor.enforce()
        #expect(try h.read { try KeyValueRepository.date($0, key) } == first, "the start of the episode is not moved")
        h.disk.set(available: 50 * GiB)
        await guardActor.enforce()
        #expect(try h.read { try KeyValueRepository.date($0, key) } == nil)
    }

    @Test func lowWatermarkHoldsOnlyRateLimitedWorkWithHysteresis() async throws {
        let h = try await Harness()
        let guardActor = makeGuard(h)
        h.disk.set(available: 14 * GiB)
        #expect(denial(await guardActor.admit(rateLimited: true, estimatedBytes: 1, sizeLimit: nil)) == .rateLimited(.lowDisk))
        #expect(isGranted(await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil)), "incremental work still runs")
        h.disk.set(available: 18 * GiB)
        #expect(denial(await guardActor.admit(rateLimited: true, estimatedBytes: 1, sizeLimit: nil)) == .rateLimited(.lowDisk), "needs low + 5 GiB to resume")
        h.disk.set(available: 21 * GiB)
        #expect(isGranted(await guardActor.admit(rateLimited: true, estimatedBytes: 1, sizeLimit: nil)))
    }

    @Test func powerAndThermalGatesApplyToRateLimitedWorkOnly() async throws {
        let h = try await Harness()
        let guardActor = makeGuard(h)
        h.system.set(SystemSnapshot(onACPower: false))
        #expect(denial(await guardActor.admit(rateLimited: true, estimatedBytes: 1, sizeLimit: nil)) == .rateLimited(.notOnACPower))
        #expect(isGranted(await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil)))
        h.system.set(SystemSnapshot(lowPowerMode: true))
        #expect(denial(await guardActor.admit(rateLimited: true, estimatedBytes: 1, sizeLimit: nil)) == .rateLimited(.lowPowerMode))
        h.system.set(SystemSnapshot(thermal: .serious))
        #expect(denial(await guardActor.admit(rateLimited: true, estimatedBytes: 1, sizeLimit: nil)) == .rateLimited(.thermal))
        try await h.update { $0.backfillOnlyOnACPower = false }
        h.system.set(SystemSnapshot(onACPower: false))
        #expect(isGranted(await guardActor.admit(rateLimited: true, estimatedBytes: 1, sizeLimit: nil)), "the AC-only setting is off")
    }

    @Test func stagingCapAllowsOneExportWhenNothingIsStaged() async throws {
        let h = try await Harness()
        try await h.update { $0.stagingSoftLimitBytes = 100 }
        let guardActor = makeGuard(h)
        guard case .granted(let first) = await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil) else {
            Issue.record("the single-export exception must admit one export")
            return
        }
        try h.seedStaged("big", bytes: 200)
        #expect(denial(await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil)) == .stopAll(.stagingFull))
        await guardActor.finish(first, actualBytes: nil)
        #expect(denial(await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil)) == .stopAll(.stagingFull), "a kept full file counts against the cap")
    }

    @Test func twoConcurrentAdmissionsCannotBothPassTheCap() async throws {
        let h = try await Harness()
        try await h.update { $0.stagingSoftLimitBytes = 0 }
        let guardActor = makeGuard(h)
        async let a = guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil)
        async let b = guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil)
        let results = await [a, b]
        #expect(results.filter(isGranted).count == 1)
    }

    @Test func backfillBucketLimitsBytesPerHour() async throws {
        let h = try await Harness()
        try await h.update { $0.backfillBytesPerHour = 100 }
        let guardActor = makeGuard(h)
        #expect(isGranted(await guardActor.admit(rateLimited: true, estimatedBytes: 60, sizeLimit: nil)))
        #expect(denial(await guardActor.admit(rateLimited: true, estimatedBytes: 60, sizeLimit: nil)) == .rateLimited(nil))
        #expect(isGranted(await guardActor.admit(rateLimited: false, estimatedBytes: 60, sizeLimit: nil)), "incremental is not rate limited")
        h.clock.advance(by: 3600)
        #expect(isGranted(await guardActor.admit(rateLimited: true, estimatedBytes: 60, sizeLimit: nil)))
    }

    @Test func checkpointCancelsOnDiskAndOnSizeRule() async throws {
        let h = try await Harness { $0.exportCheckpointBytes = 10 }
        let guardActor = makeGuard(h)
        guard case .granted(let sized) = await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: 50) else {
            Issue.record("expected a permit")
            return
        }
        #expect(sized.control.record(bytes: 20))
        #expect(!sized.control.record(bytes: 40))
        #expect(sized.reason == .sizeRule)
        guard case .granted(let slow) = await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil) else {
            Issue.record("expected a permit")
            return
        }
        h.disk.set(available: 2 * GiB)
        #expect(!slow.control.record(bytes: 20))
        #expect(slow.reason == .disk)
    }

    @Test func unreadableDiskDeniesInsteadOfGuessing() async throws {
        struct BrokenDisk: DiskSpaceProvider {
            func capacity(of url: URL) throws -> DiskCapacity { throw CocoaError(.fileReadUnknown) }
        }
        let h = try await Harness()
        var env = h.env
        env.disk = BrokenDisk()
        let guardActor = ResourceGuard(env: env, staging: StagingManager(env: env))
        #expect(denial(await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil)) == .stopAll(.criticalDisk))
    }
}

@Suite struct StagingManagerTests {
    @Test func pathIsGenerationNamedUnderHashedDirectory() async throws {
        let h = try await Harness()
        let staging = StagingManager(env: h.env)
        let key = AssetKey.local("abc")
        let url = staging.fileURL(assetKey: key, type: .fullSizePhoto, generation: 3)
        #expect(url.lastPathComponent == "5.3")
        #expect(url.deletingLastPathComponent().lastPathComponent == String(key.sha256Hex.prefix(32)))
        #expect(url.path.hasPrefix(h.staging.path))
    }

    @Test func orphanCleanupKeepsReferencedFilesAndRepairsMissingOnes() async throws {
        let h = try await Harness()
        try h.addDrive()
        let kept = try h.seedStaged("kept")
        let missing = try h.seedStaged("missing", writeFile: false)
        let staging = StagingManager(env: h.env)
        let stray = staging.fileURL(assetKey: .local("kept"), type: .photo, generation: 9)
        try Data([1]).write(to: stray)
        let partial = h.staging.appendingPathComponent("zz/leftover.part")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: partial)
        // An uploading job protects its generation even without a ready row.
        let uploadingFile = staging.fileURL(assetKey: .local("up"), type: .photo, generation: 2)
        try FileManager.default.createDirectory(at: uploadingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([2]).write(to: uploadingFile)
        try h.write { db in
            var job = UploadJob(destinationId: .googleDrive, assetKey: .local("up"), resType: .photo, origin: .incremental, state: .uploading, uploadingGen: 2, updatedAt: h.clock.now)
            try JobRepository.save(db, &job)
        }
        let removed = try await staging.cleanupOrphans()
        #expect(removed == 2)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: uploadingFile.path))
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let state = try h.read { db in try ResourceRepository.fetch(db, key: .local("missing"), type: .photo)?.stagingState }
        #expect(state == StagingState.none)
        _ = missing
    }

    @Test func releasesWhenNoAvailableDestinationNeedsTheFile() async throws {
        let h = try await Harness()
        try h.addDrive()
        try h.addNAS()
        let needed = try h.seedStaged("needed", job: (.googleDrive, .pending))
        let unneeded = try h.seedStaged("unneeded", job: (.googleDrive, .done))
        let offlineOnly = try h.seedStaged("offline", job: (h.nasId, .pending))
        try h.write { db in
            try DestinationRepository.setStatus(db, id: h.nasId, status: .unavailable(.offline), now: h.clock.now)
        }
        let staging = StagingManager(env: h.env)
        #expect(try await staging.releaseUnneeded() == 2)
        #expect(FileManager.default.fileExists(atPath: needed.path))
        #expect(!FileManager.default.fileExists(atPath: unneeded.path))
        #expect(!FileManager.default.fileExists(atPath: offlineOnly.path), "files are not kept for an offline destination (8.9.3)")
    }

    @Test func aFileAnUploadReadsIsNeverDeleted() async throws {
        let h = try await Harness()
        try h.addDrive()
        let url = try h.seedStaged("reading", job: (.googleDrive, .done), lastUsed: h.clock.now.addingTimeInterval(-10 * 3600))
        let staging = StagingManager(env: h.env)
        await staging.lease(url.path)
        #expect(try await staging.releaseUnneeded() == 0)
        h.clock.advance(by: 3 * 3600)
        #expect(try await staging.expireIdle() == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        await staging.unlease(url.path)
        #expect(try await staging.expireIdle() == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func idleFilesExpireAfterTwoHoursEvenIfStillWanted() async throws {
        let h = try await Harness()
        try h.addDrive()
        let fresh = try h.seedStaged("fresh", job: (.googleDrive, .pending))
        let staging = StagingManager(env: h.env)
        h.clock.advance(by: 3600)
        #expect(try await staging.expireIdle() == 0)
        h.clock.advance(by: 3600 + 1)
        #expect(try await staging.expireIdle() == 1)
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        let state = try h.read { db in try ResourceRepository.fetch(db, key: .local("fresh"), type: .photo)?.stagingState }
        #expect(state == StagingState.none, "the row is released before the file goes, so no row points at a missing file")
    }

    @Test func staleGenerationIsReleased() async throws {
        let h = try await Harness()
        try h.addDrive()
        try h.seedStaged("edited", gen: 1, job: (.googleDrive, .pending))
        try h.write { db in
            try db.execute(sql: "UPDATE upload_job SET target_gen = 2")
        }
        #expect(try await StagingManager(env: h.env).releaseUnneeded() == 1)
    }
}
