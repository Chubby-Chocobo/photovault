import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

private let GiB = GlobalSettings.GiB

/// A library with backfill work (scanned before the baseline moment passed) and one new photo.
private func backfillAndIncremental(_ h: Harness) async throws {
    try h.addDrive(scope: .full)
    for i in 0..<3 { await h.add(h.snapshot("old\(i)", daysAgo: Double(5 + i)), recordChange: false) }
    try await h.baseline(.googleDrive)
    _ = try await h.coordinator.scanner.run()
    h.clock.advance(by: 60)
    await h.add(h.snapshot("new", daysAgo: 0))
}

@Suite struct DiskAndPowerTests {
    @Test func t14LowDiskStopsBackfillAndClassificationButIncrementalContinues() async throws {
        let h = try await Harness()
        try await backfillAndIncremental(h)
        h.disk.set(available: 10 * GiB)
        await h.run()
        let names = await h.fileNames(h.drive)
        #expect(names.count == 1 && names[0].hasSuffix("_IMG_new.HEIC"), "only the incremental photo moved: \(names)")
        #expect(await h.fakePhotos.headerReads == ["new"], "backfill classification is held too")
        #expect(try h.jobs(.pending).isEmpty, "backfill photos are still provisional, so they have no jobs yet")

        h.disk.set(available: 40 * GiB)
        await h.run()
        #expect(await h.drive.files.count == 4)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
    }

    @Test func t14CriticalDiskStopsEverythingIncludingIncrementalAndClassification() async throws {
        let h = try await Harness()
        try await backfillAndIncremental(h)
        h.disk.set(available: 3 * GiB)
        await h.run()
        #expect(await h.drive.files.isEmpty)
        #expect(await h.fakePhotos.headerReads.isEmpty)
        #expect(await h.fakePhotos.exportCount.isEmpty)
        #expect(h.stagingFiles().isEmpty)

        h.disk.set(available: 40 * GiB)
        await h.run()
        #expect(await h.drive.files.count == 4)
    }

    @Test func t14ExportRunningWhenDiskTurnsCriticalIsCancelledWithoutCountingAsAnError() async throws {
        let h = try await Harness { $0.exportCheckpointBytes = 1 }
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("big", daysAgo: 0.5), recordChange: false)
        try await h.baseline(.googleDrive)
        h.disk.set(available: 40 * GiB)
        let disk = h.disk
        h.photos.beforeExport = { _, _, control in
            disk.set(available: 3 * GiB)
            if !control.record(bytes: 1) { throw PhotosSourceError.cancelled }
        }
        await h.run()
        let resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("big"), type: .photo) })
        #expect(resource.stagingState == .none)
        #expect(resource.diskCancelCount == 1)
        #expect(resource.exportAttempts == 0, "a disk cancel is not an error (FR-31)")
        #expect(resource.stagingPath == nil)
        #expect(h.stagingFiles().isEmpty, "the partial file is removed")
        #expect(try h.jobs(.pending).count == 1)
    }

    @Test func t14TwoCancelsOnASmallDiskMarkTheFileTooLargeAndOutsideTheThirtyDayCycle() async throws {
        let h = try await Harness { $0.exportCheckpointBytes = 1 }
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.add(h.snapshot("huge", daysAgo: 0.5))
        let disk = h.disk
        h.photos.beforeExport = { _, _, control in
            disk.set(available: 3 * GiB)
            if !control.record(bytes: 1) { throw PhotosSourceError.cancelled }
        }
        for _ in 0..<2 {
            h.disk.set(available: 6 * GiB)
            await h.run()
        }
        let job = try #require(try h.jobs().first)
        #expect(job.state == .deferred && job.stateReason == .tooLargeForDisk)
        let resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("huge"), type: .photo) })
        #expect(resource.tooLargeForDisk && resource.diskCancelCount == 2)

        // The disk is still small: after 40 days the job is retried (every 24 h) and cancelled
        // again; the 30-day rule never skips it.
        h.disk.set(available: 5 * GiB)
        h.clock.advance(by: 40 * 86_400)
        await h.run()
        let later = try #require(try h.jobs().first)
        #expect(later.state != .skipped && later.stateReason != .deferredTooLong)
        #expect(await h.drive.files.isEmpty)

        // Free space grows past what the file reached plus the margin: it goes through by itself.
        h.photos.beforeExport = nil
        h.disk.set(available: 100 * GiB)
        await h.run()
        #expect(await h.drive.files.count == 1)
        #expect(try h.jobs().first?.state == .done)
    }

    @Test func t15OnBatteryStopsBackfillButIncrementalContinues() async throws {
        let h = try await Harness()
        try await backfillAndIncremental(h)
        h.system.set(SystemSnapshot(onACPower: false))
        await h.run()
        #expect(await h.fileNames(h.drive).count == 1)
        #expect(await h.fakePhotos.headerReads == ["new"])

        h.system.set(SystemSnapshot(onACPower: true))
        await h.run()
        #expect(await h.drive.files.count == 4)
    }

    @Test(arguments: [
        SystemSnapshot(lowPowerMode: true),
        SystemSnapshot(thermal: .serious),
        SystemSnapshot(thermal: .critical),
    ])
    func t15LowPowerAndThermalStopBackfill(_ conditions: SystemSnapshot) async throws {
        let h = try await Harness()
        try await backfillAndIncremental(h)
        h.system.set(conditions)
        await h.run()
        #expect(await h.fileNames(h.drive).count == 1)
        h.system.set(SystemSnapshot())
        await h.run()
        #expect(await h.drive.files.count == 4)
    }

    @Test func backfillIsLimitedToTheConfiguredRatePerHour() async throws {
        let h = try await Harness()
        try await h.update { $0.backfillBytesPerHour = 20 << 20 }
        try h.addDrive(scope: .full)
        for i in 0..<6 { await h.add(h.snapshot("b\(i)", daysAgo: Double(2 + i)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.run()
        let first = await h.drive.files.count
        #expect(first > 0 && first < 6, "the bucket admits only a few estimates per hour: \(first)")
        for _ in 0..<6 {
            h.clock.advance(by: 3600)
            await h.run()
        }
        #expect(await h.drive.files.count == 6)
    }

    @Test func uploadsAreHeldOnExpensiveNetworkOrWithoutPowerWhenConfigured() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("x"), recordChange: false)
        try await h.baseline(.googleDrive)
        h.system.set(SystemSnapshot(networkExpensive: true))
        var outcome = await h.run()
        guard case .completed(let report) = outcome else {
            Issue.record("not completed")
            return
        }
        #expect(report.uploadsHeld && report.uploaded == 0)
        #expect(await h.drive.files.isEmpty)
        #expect(report.exported == 1, "export continues; only the network is spared")

        h.system.set(SystemSnapshot())
        try await h.update { $0.allUploadsOnlyOnACPower = true }
        h.system.set(SystemSnapshot(onACPower: false))
        outcome = await h.run()
        #expect(await h.drive.files.isEmpty)
        h.system.set(SystemSnapshot())
        await h.run()
        #expect(await h.drive.files.count == 1)
    }
}
