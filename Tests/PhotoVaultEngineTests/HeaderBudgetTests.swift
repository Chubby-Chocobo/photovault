import PhotoVaultCore
import Testing
@testable import PhotoVaultEngine

/// A header read can buffer up to the classifier's in-memory cap; the guard is told so.
@Suite struct HeaderBudgetTests {
    @Test func anUnknownSizeReservesTheWholeBuffer() {
        #expect(ClassifyWorker.headerBudget(fileSize: nil) == 32 << 20)
    }

    @Test func aSmallFileReservesItsOwnSize() {
        #expect(ClassifyWorker.headerBudget(fileSize: 300_000) == 300_000)
    }

    @Test func aLargeFileIsCappedAtTheBuffer() {
        #expect(ClassifyWorker.headerBudget(fileSize: 4 << 30) == 32 << 20)
    }

    @Test func anEmptyOrNegativeSizeStillReservesOneByte() {
        #expect(ClassifyWorker.headerBudget(fileSize: 0) == 1)
        #expect(ClassifyWorker.headerBudget(fileSize: -5) == 1)
    }

    @Test func headerReadsInFlightCountAgainstTheStagingCapAtTheirReservedSize() async throws {
        let h = try await Harness()
        try await h.update { $0.stagingSoftLimitBytes = 100 << 20 }
        let guardActor = ResourceGuard(env: h.env, staging: StagingManager(env: h.env))
        let reserved = ClassifyWorker.headerBudget(fileSize: nil)
        var granted = 0
        var stopped = false
        for _ in 0..<6 {
            switch await guardActor.admit(rateLimited: false, estimatedBytes: 1, sizeLimit: nil, reservedBytes: reserved) {
            case .granted: granted += 1
            case .denied(let denial): stopped = denial == .stopAll(.stagingFull)
            }
        }
        #expect(granted == 4 && stopped, "four 32 MiB buffers fit under 100 MiB, the fifth does not: \(granted)")
    }
}
