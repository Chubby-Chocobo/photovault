import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

final class ExportAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite struct ExportPassFailureTests {
    private func preparedHarness(newPhotos: Int) async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.run()
        for i in 0..<newPhotos { await h.add(h.snapshot("new\(i)")) }
        _ = try await h.coordinator.tracker.process()
        _ = try await h.coordinator.classifier.runPass()
        try await h.coordinator.finalize.placeLeftovers()
        return h
    }

    @Test(arguments: [PhotosSourceError.notAuthorized, .libraryUnavailable, .cancelled])
    func passEndsWhenPhotosIsLost(error: PhotosSourceError) async throws {
        let h = try await preparedHarness(newPhotos: 5)
        let attempts = ExportAttemptCounter()
        h.photos.beforeExport = { _, _, _ in
            attempts.bump()
            throw error
        }
        let result = try await h.coordinator.exporter.runPass()
        #expect(result.photosUnavailable)
        #expect(attempts.value == result.failed)
        #expect(attempts.value <= h.env.tuning.maxConcurrentExports)
        // The failed resources wait for a short delay instead of being picked straight away.
        let before = attempts.value
        let again = try await h.coordinator.exporter.runPass()
        #expect(attempts.value - before == again.failed)
        h.photos.beforeExport = nil
        h.clock.advance(by: ExportWorker.transientRetryDelay + 1)
        var exported = 0
        for _ in 0..<5 { exported += try await h.coordinator.exporter.runPass().exported }
        #expect(exported == 5)
    }

    @Test func itemFailureIsNotRetriedInTheSamePass() async throws {
        let h = try await preparedHarness(newPhotos: 3)
        let attempts = ExportAttemptCounter()
        h.photos.beforeExport = { _, _, _ in
            attempts.bump()
            throw PhotosSourceError.networkError
        }
        let result = try await h.coordinator.exporter.runPass()
        #expect(attempts.value == 3)
        #expect(result.failed == 3)
        #expect(!result.photosUnavailable)
    }
}
