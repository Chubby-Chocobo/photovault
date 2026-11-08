import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct DestinationHealthTests {
    /// A signed-out destination waits for the owner to sign in again: a cycle that finds it reachable
    /// must not switch it back on, or it would upload with whatever token it holds against stale state.
    @Test func aSignedOutDestinationStaysSignedOutAndUploadsNothing() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        try h.write { db in
            try DestinationRepository.setStatus(db, id: .googleDrive, status: .paused(.signedOut), now: Date())
        }
        await h.add(h.snapshot("new", daysAgo: 0), recordChange: true)
        await h.settle()
        #expect(try h.destinationRecord(.googleDrive).status == .paused(.signedOut))
        #expect(await h.count(of: .upload, on: h.drive) == 0)
    }
}
