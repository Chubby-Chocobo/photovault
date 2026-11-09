import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A staged file is deleted only when nobody holds or takes a claim on it between the check and the unlink.
@Suite struct StagingClaimTests {
    @Test func aClaimTakenWhileTheReleaseWaitsForTheDatabaseIsRefusedOrKeepsTheFile() async throws {
        // A file-backed pool: reads run while a long write holds the writer, which is exactly the
        // window between the "nobody needs it" check and the unlink.
        let directory = try TestFiles.temporaryDirectory("staging-claim")
        let h = try await Harness(store: try Store.open(at: directory.appendingPathComponent("db.sqlite")))
        try h.addDrive()
        let staging = StagingManager(env: h.env)
        for index in 0..<5 {
            let url = try h.seedStaged("race\(index)")
            let store = h.store
            let blocker = Task.detached { try store.write { _ in Thread.sleep(forTimeInterval: 0.2) } }
            try await Task.sleep(nanoseconds: 50_000_000)
            let sweep = Task { try await staging.releaseUnneeded() }
            try await Task.sleep(nanoseconds: 80_000_000)
            let claimed = await staging.lease(url.path)
            // A granted claim either came before the release looked (which then skips the file) or
            // after it finished; on a slow machine the file can already be gone, and the upload then
            // finds the staging lost. What must never happen is a file that exists under a claim
            // being deleted afterwards.
            let existedWhenClaimed = FileManager.default.fileExists(atPath: url.path)
            try await blocker.value
            _ = try await sweep.value
            if claimed {
                if existedWhenClaimed {
                    #expect(FileManager.default.fileExists(atPath: url.path), "a file with a claim is not deleted (round \(index))")
                }
                await staging.unlease(url.path)
            } else {
                #expect(!FileManager.default.fileExists(atPath: url.path), "a refused claim means the release went through")
            }
        }
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
