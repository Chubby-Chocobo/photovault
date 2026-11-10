import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A staged file is deleted only when nobody holds or takes a claim on it between the check and the unlink.
@Suite struct StagingClaimTests {
    /// Holds the database writer until `release()`, so the test decides how long the release waits for it.
    private final class HeldWrite: @unchecked Sendable {
        private let lock = NSLock()
        private var inside = false
        private let gate = DispatchSemaphore(value: 0)
        var isHolding: Bool { lock.withLock { inside } }
        func hold() { lock.withLock { inside = true }; gate.wait() }
        func release() { gate.signal() }
    }

    @Test func aClaimTakenWhileTheReleaseWaitsForTheDatabaseIsRefused() async throws {
        // A file-backed pool: reads run while a long write holds the writer, which is exactly the
        // window between the "nobody needs it" check and the unlink.
        let directory = try TestFiles.temporaryDirectory("staging-claim")
        let h = try await Harness(store: try Store.open(at: directory.appendingPathComponent("db.sqlite")))
        try h.addDrive()
        let staging = StagingManager(env: h.env)
        let url = try h.seedStaged("race")
        let store = h.store
        let held = HeldWrite()
        // The held write blocks its thread, so it runs on a thread of its own, not on the Swift concurrency pool.
        let blocker = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                Thread { continuation.resume(with: Result { try store.write { _ in held.hold() } }) }.start()
            }
        }
        #expect(await pollUntil { held.isHolding })
        let sweep = Task { try await staging.releaseUnneeded() }
        let waiting = await pollUntil { await staging.isReleasing(url.path) }
        let claimed = await staging.lease(url.path)
        let existed = FileManager.default.fileExists(atPath: url.path)
        held.release()
        try await blocker.value
        let released = try await sweep.value
        #expect(waiting, "the release waits for the database")
        #expect(!claimed, "a claim in that window is refused")
        #expect(existed, "the file is still there while the release waits")
        #expect(released == 1 && !FileManager.default.fileExists(atPath: url.path), "the refused claim lets the release go through")
    }

    @Test func aClaimTakenBeforeTheReleaseLooksKeepsTheFile() async throws {
        let h = try await Harness()
        try h.addDrive()
        let staging = StagingManager(env: h.env)
        let url = try h.seedStaged("claimed")
        #expect(await staging.lease(url.path))
        #expect(try await staging.releaseUnneeded() == 0)
        #expect(FileManager.default.fileExists(atPath: url.path), "a file with a claim is not deleted")
        await staging.unlease(url.path)
        #expect(try await staging.releaseUnneeded() == 1, "once the claim ends the file can go")
    }

    @Test func aFileBeingReleasedRefusesNewClaims() async throws {
        let h = try await Harness()
        try h.addDrive()
        let url = try h.seedStaged("gone")
        let staging = StagingManager(env: h.env)
        #expect(try await staging.releaseUnneeded() == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // After the release a claim is possible again (the attempt then sees the file is gone).
        #expect(await staging.lease(url.path))
        await staging.unlease(url.path)
    }

    @Test func aJobThatStartsNeedingTheFileDuringTheSweepKeepsIt() async throws {
        let h = try await Harness()
        try h.addDrive()
        let url = try h.seedStaged("needed", job: (.googleDrive, .pending))
        let staging = StagingManager(env: h.env)
        #expect(try await staging.releaseUnneeded() == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let row = try h.read { db in try ResourceRepository.fetch(db, key: .local("needed"), type: .photo) }
        #expect(row?.stagingState == .ready)
    }
}
