import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// The "không sync được quá 24 giờ" notification depends on this time moving only on real progress.
@Suite struct LastSuccessfulSyncTests {
    private func lastSync(_ h: Harness) throws -> Date? {
        try h.read { try KeyValueRepository.date($0, KeyValueRepository.Key.lastSuccessfulSyncAt) }
    }

    @Test func aCycleThatCannotUploadWhatIsWaitingIsNotASuccess() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("p", daysAgo: 1), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.drive.failNext(.upload, with: .server(status: 503), times: 1_000)
        await h.drive.failNext(.resume, with: .server(status: 503), times: 1_000)
        await h.settle()
        #expect(try lastSync(h) == nil)
    }

    @Test func uploadingOrHavingNothingLeftIsASuccess() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("p", daysAgo: 1), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let first = try #require(try lastSync(h))
        h.clock.advance(by: 3600)
        await h.run()
        #expect(try lastSync(h).map { $0 > first } == true, "an idle cycle with nothing waiting still counts")
    }
}
