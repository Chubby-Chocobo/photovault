import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct DiskGuardPolicyTests {
    static let gib = GlobalSettings.GiB
    let settings = GlobalSettings()  // low 15, critical 5, soft 4

    func input(
        free: Int64 = 100, staging: Int64 = 0, inFlight: Int64 = 0, active: Int = 0, rateLimited: Bool = false,
        system: SystemSnapshot = SystemSnapshot(), paused: Bool = false
    ) -> DiskGuardInput {
        DiskGuardInput(
            capacity: DiskCapacity(available: free * Self.gib, availableForImportantUsage: free * Self.gib, total: 500 * Self.gib),
            stagingBytes: staging * Self.gib, inFlightBytes: inFlight * Self.gib, activeExportCount: active,
            settings: settings, isRateLimited: rateLimited, system: system, rateLimitedPaused: paused
        )
    }

    @Test func healthyDiskAllowsExport() {
        let decision = DiskGuardPolicy.evaluate(input())
        #expect(decision.mayStartExport && !decision.mustCancelAll && decision.blockedBy == nil)
    }

    @Test func softStagingLimitBlocksNewExports() {
        #expect(DiskGuardPolicy.evaluate(input(staging: 3, inFlight: 0, active: 1)).mayStartExport)
        let full = DiskGuardPolicy.evaluate(input(staging: 2, inFlight: 2, active: 1))
        #expect(!full.mayStartExport && full.blockedBy == .stagingFull)
    }

    @Test func twoConcurrentExportsShareTheSoftLimit() {
        // First export is admitted by the empty-staging exception; its bytes then count.
        #expect(DiskGuardPolicy.evaluate(input(staging: 0, inFlight: 0, active: 0)).mayStartExport)
        #expect(DiskGuardPolicy.evaluate(input(staging: 0, inFlight: 1, active: 1)).mayStartExport)
        #expect(!DiskGuardPolicy.evaluate(input(staging: 0, inFlight: 5, active: 1)).mayStartExport)
        #expect(!DiskGuardPolicy.evaluate(input(staging: 6, inFlight: 0, active: 0)).mayStartExport)
    }

    @Test func singleExportExceptionOnlyWhenNothingStagedOrRunning() {
        var tiny = settings
        tiny.stagingSoftLimitBytes = 0
        func make(staging: Int64, active: Int) -> DiskGuardInput {
            DiskGuardInput(
                capacity: DiskCapacity(available: 100 * Self.gib, availableForImportantUsage: 100 * Self.gib, total: 500 * Self.gib),
                stagingBytes: staging, inFlightBytes: 0, activeExportCount: active, settings: tiny, isRateLimited: false,
                system: SystemSnapshot()
            )
        }
        #expect(DiskGuardPolicy.evaluate(make(staging: 0, active: 0)).mayStartExport)
        #expect(!DiskGuardPolicy.evaluate(make(staging: 0, active: 1)).mayStartExport)
        #expect(!DiskGuardPolicy.evaluate(make(staging: 1, active: 0)).mayStartExport)
    }

    @Test func criticalCancelsEverythingEvenTheExceptionExport() {
        let decision = DiskGuardPolicy.evaluate(input(free: 4))
        #expect(decision.mustCancelAll && !decision.mayStartExport && decision.blockedBy == .criticalDisk)
        #expect(decision.rateLimitedPaused)
        #expect(!DiskGuardPolicy.evaluate(input(free: 5)).mustCancelAll)
    }

    @Test func belowLowStopsOnlyRateLimitedExports() {
        let free = input(free: 10, rateLimited: false)
        #expect(DiskGuardPolicy.evaluate(free).mayStartExport)
        let limited = DiskGuardPolicy.evaluate(input(free: 10, rateLimited: true))
        #expect(!limited.mayStartExport && limited.blockedBy == .lowDisk && limited.stopRateLimitedExports)
    }

    @Test func hysteresisResumesOnlyAtLowPlusFiveGiB() {
        var decision = DiskGuardPolicy.evaluate(input(free: 14, rateLimited: true))
        #expect(decision.rateLimitedPaused)
        decision = DiskGuardPolicy.evaluate(input(free: 19, rateLimited: true, paused: decision.rateLimitedPaused))
        #expect(decision.rateLimitedPaused && !decision.mayStartExport)
        decision = DiskGuardPolicy.evaluate(input(free: 20, rateLimited: true, paused: decision.rateLimitedPaused))
        #expect(!decision.rateLimitedPaused && decision.mayStartExport)
        // Between low and low + 5 while running stays running.
        #expect(!DiskGuardPolicy.evaluate(input(free: 17, rateLimited: true, paused: false)).rateLimitedPaused)
    }

    @Test(arguments: [
        (SystemSnapshot(onACPower: false), DiskGuardBlock.notOnACPower),
        (SystemSnapshot(lowPowerMode: true), DiskGuardBlock.lowPowerMode),
        (SystemSnapshot(thermal: .serious), DiskGuardBlock.thermal),
        (SystemSnapshot(thermal: .critical), DiskGuardBlock.thermal),
    ])
    func rateLimitedExportsNeedPowerAndCoolHardware(system: SystemSnapshot, block: DiskGuardBlock) {
        let limited = DiskGuardPolicy.evaluate(input(rateLimited: true, system: system))
        #expect(!limited.mayStartExport && limited.blockedBy == block && limited.stopRateLimitedExports)
        #expect(DiskGuardPolicy.evaluate(input(rateLimited: false, system: system)).mayStartExport)
    }

    @Test func fairThermalIsStillFine() {
        #expect(DiskGuardPolicy.evaluate(input(rateLimited: true, system: SystemSnapshot(thermal: .fair))).mayStartExport)
    }

    @Test func tooLargeForDiskAfterTwoCancels() {
        let critical = settings.criticalWatermarkBytes
        let g = Self.gib
        // received 3 + free 6 = 9 < 5 + 5
        #expect(DiskGuardPolicy.isTooLargeForDisk(diskCancelCount: 2, bytesReceivedAtCancel: 3 * g, freeAtStart: 6 * g, criticalWatermarkBytes: critical))
        #expect(!DiskGuardPolicy.isTooLargeForDisk(diskCancelCount: 1, bytesReceivedAtCancel: 3 * g, freeAtStart: 6 * g, criticalWatermarkBytes: critical))
        #expect(!DiskGuardPolicy.isTooLargeForDisk(diskCancelCount: 3, bytesReceivedAtCancel: 5 * g, freeAtStart: 5 * g, criticalWatermarkBytes: critical))
        #expect(!DiskGuardPolicy.isTooLargeForDisk(diskCancelCount: 2, bytesReceivedAtCancel: nil, freeAtStart: 0, criticalWatermarkBytes: critical))
    }

    @Test func retryNeedsKnownSizePlusFiveGiB() {
        let g = Self.gib
        #expect(DiskGuardPolicy.mayRetryTooLarge(freeBytes: 25 * g, knownSizeBytes: 20 * g))
        #expect(!DiskGuardPolicy.mayRetryTooLarge(freeBytes: 25 * g - 1, knownSizeBytes: 20 * g))
        #expect(!DiskGuardPolicy.mayRetryTooLarge(freeBytes: 500 * g, knownSizeBytes: nil))
    }
}
