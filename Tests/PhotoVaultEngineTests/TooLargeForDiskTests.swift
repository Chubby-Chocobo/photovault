import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// FR-31: "too large for the disk" is a property of the resource, so every job for it is deferred,
/// counted, and tried again when the disk allows (or after 24 h).
@Suite struct TooLargeForDiskTests {
    private let GiB: Int64 = 1 << 30

    /// A video the disk cannot hold: two cancelled exports on a small disk.
    private func tooLargeVideo() async throws -> Harness {
        let h = try await Harness { $0.exportCheckpointBytes = 1 }
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.add(h.snapshot("huge", daysAgo: 0.5))
        let disk = h.disk
        h.photos.beforeExport = { _, _, control in
            disk.set(available: 3 * 1_073_741_824)
            if !control.record(bytes: 1) { throw PhotosSourceError.cancelled }
        }
        for _ in 0..<2 {
            h.disk.set(available: 6 * GiB)
            await h.run()
        }
        let resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("huge"), type: .photo) })
        #expect(resource.tooLargeForDisk)
        return h
    }

    @Test func aJobCreatedLaterForTheMarkedResourceIsDeferredAndCounted() async throws {
        let h = try await tooLargeVideo()
        try h.addNAS(scope: .full)
        try await h.coordinator.destinationAdded(h.nasId)
        h.disk.set(available: 3 * GiB)
        await h.run()
        let nasJob = try #require(try h.jobs(.deferred, destination: h.nasId).first)
        #expect(nasJob.stateReason == .tooLargeForDisk)
        #expect(try h.jobs(.pending).isEmpty)
        #expect(await h.coordinator.currentSnapshot().deferred == 2, "the owner sees both files waiting")
        #expect(await h.nas.files.isEmpty)
    }

    @Test func itIsTriedAgainAsSoonAsTheFreeSpaceCoversTheBytesItReachedPlusTheMargin() async throws {
        let h = try await tooLargeVideo()
        let exports = Box(0)
        h.photos.beforeExport = { _, _, _ in exports.mutate { $0 += 1 } }
        // The file reached 1 byte: 5 GiB free is the critical watermark, not yet 5 GiB + 1 byte.
        h.disk.set(available: 5 * GiB)
        h.clock.advance(by: 3600)
        await h.run()
        #expect(exports.get() == 0, "not tried")
        let waiting = try #require(try h.jobs().first)
        #expect(waiting.state == .deferred && waiting.stateReason == .tooLargeForDisk)

        h.disk.set(available: 5 * GiB + 2)
        await h.run()
        #expect(exports.get() == 1)
        #expect(await h.drive.files.count == 1)
        #expect(try h.jobs().first?.state == .done)
    }

    @Test func itIsTriedAgainAfter24HoursWhateverTheFreeSpace() async throws {
        let h = try await tooLargeVideo()
        let exports = Box(0)
        let disk = h.disk
        h.photos.beforeExport = { _, _, control in
            exports.mutate { $0 += 1 }
            disk.set(available: 3 * 1_073_741_824)
            if !control.record(bytes: 1) { throw PhotosSourceError.cancelled }
        }
        h.disk.set(available: 5 * GiB)
        h.clock.advance(by: 23 * 3600)
        await h.run()
        #expect(exports.get() == 0, "a day has not passed")

        h.disk.set(available: 5 * GiB)
        h.clock.advance(by: 2 * 3600)
        await h.run()
        #expect(exports.get() >= 1, "the 24 h retry happened")
        #expect(try h.jobs().first?.state != .done)
    }

    @Test func retryDeferredReArmsAResourceWhoseOnlyJobsArePending() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.add(h.snapshot("late", daysAgo: 0.5))
        // The export is interrupted without a result: the job exists and is pending.
        h.photos.beforeExport = { _, _, _ in throw PhotosSourceError.cancelled }
        await h.run()
        #expect(try h.jobs(.pending).count == 1)
        try h.write { db in
            try db.execute(sql: "UPDATE resource SET too_large_for_disk = 1, disk_cancel_count = 2")
        }
        h.photos.beforeExport = nil
        try await h.coordinator.retryDeferred(nil)
        let resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("late"), type: .photo) })
        #expect(!resource.tooLargeForDisk && resource.diskCancelCount == 0)
        await h.settle()
        #expect(await h.drive.files.count == 1)
    }
}
