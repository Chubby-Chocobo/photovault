import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// The latest integrity result of a destination is kept, whoever started the check, and checksum
/// mismatches reach the owner as a decision of their own (FR-61, FR-76).
@Suite struct IntegrityResultTests {
    private func mediaFiles(_ root: URL) -> [String: Int] {
        treeListing(root).filter { !$0.key.hasPrefix(".photovault") && !$0.key.hasSuffix(".json") && !$0.key.hasSuffix(".xmp") }
    }

    /// A local destination with four backed-up files: one gone, one truncated, two rotted.
    private func damagedLocal() async throws -> (Harness, URL) {
        let h = try await Harness()
        let (_, root, _) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        for index in 0..<4 { await h.add(h.snapshot("q\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(h.nasId)
        await h.settle()
        let files = mediaFiles(root).keys.sorted()
        #expect(files.count == 4)
        try FileManager.default.removeItem(at: root.appendingPathComponent(files[0]))
        try Data("x".utf8).write(to: root.appendingPathComponent(files[1]))
        for name in files[2...] {
            var data = try Data(contentsOf: root.appendingPathComponent(name))
            data[0] ^= 0xFF
            try data.write(to: root.appendingPathComponent(name))
        }
        return (h, root)
    }

    @Test func missingFilesAndMismatchesAreReportedSeparately() async throws {
        let (h, _) = try await damagedLocal()
        let report = try await h.coordinator.runIntegrityCheck(h.nasId)
        #expect(report.missing == 1 && report.sizeMismatch == 1 && report.hashMismatch == 1)
        #expect(report.missingByDestination[h.nasId] == 1, "mismatches are not counted as missing")
        #expect(report.mismatchByDestination[h.nasId] == 2)
        #expect(report.skippedDestinations.isEmpty)
    }

    @Test func aManualCheckLeavesAChecksumMismatchDecisionUntilTheOwnerDismissesIt() async throws {
        let (h, _) = try await damagedLocal()
        _ = try await h.coordinator.runIntegrityCheck(h.nasId)
        let decisions = await h.coordinator.pendingOwnerDecisions()
        #expect(decisions.contains(.checksumMismatch(h.nasId, count: 2)))
        #expect(OwnerDecision.checksumMismatch(h.nasId, count: 2).destinationId == h.nasId)

        try await h.coordinator.dismissChecksumMismatch(h.nasId)
        #expect(!(await h.coordinator.pendingOwnerDecisions()).contains(.checksumMismatch(h.nasId, count: 2)))
        #expect(try h.jobs(.missingRemote).count == 3, "dismissing does not touch the files' state")
    }

    @Test func theScheduledCheckLeavesTheSameDecision() async throws {
        let (h, _) = try await damagedLocal()
        h.clock.advance(by: 8 * 24 * 3600)
        await h.run()
        #expect(try h.jobs(.missingRemote).count == 3)
        #expect(await h.coordinator.pendingOwnerDecisions().contains(.checksumMismatch(h.nasId, count: 2)))
    }

    @Test func aLaterCheckWithoutMismatchesReplacesTheResult() async throws {
        let (h, _) = try await damagedLocal()
        // Each check re-hashes a 1 % sample, so it takes a few checks to see every rotted file; once
        // all are marked, the next result has none.
        for _ in 0..<3 { _ = try await h.coordinator.runIntegrityCheck(h.nasId) }
        #expect(!(await h.coordinator.pendingOwnerDecisions()).contains { if case .checksumMismatch = $0 { true } else { false } })
    }

    @Test func confirmingTheReuploadClearsTheMismatchDecision() async throws {
        let (h, _) = try await damagedLocal()
        _ = try await h.coordinator.runIntegrityCheck(h.nasId)
        try await h.coordinator.confirmReupload(h.nasId)
        #expect(!(await h.coordinator.pendingOwnerDecisions()).contains { if case .checksumMismatch = $0 { true } else { false } })
    }

    @Test func aDriveCheckWithOnlyMissingFilesRaisesNoChecksumDecision() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        for index in 0..<2 { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        await h.drive.externallyDelete(try #require(await h.drive.files.first).id)
        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.missingByDestination[.googleDrive] == 1 && report.mismatchByDestination.isEmpty)
        let decisions = await h.coordinator.pendingOwnerDecisions()
        #expect(decisions == [.integrityMissing(.googleDrive, count: 1)])
    }

    @Test func aDestinationThatCannotBeReachedIsSkippedInsteadOfEndingTheCheck() async throws {
        let h = try await Harness()
        let wrapper = ControllableDrive(h.drive)
        h.overrides = [wrapper]
        await h.env.destinations.add(wrapper)
        try h.addDrive(scope: .full)
        for index in 0..<2 { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        wrapper.hidesListing = true
        await h.drive.failNext(.probe, with: .offline)
        await h.drive.externallyDelete(try #require(await h.drive.files.first).id)

        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.skippedDestinations == [.googleDrive])
        #expect(report.checked == 0 && report.totalProblems == 0)
        #expect(try h.jobs(.missingRemote).isEmpty)
        #expect(await h.coordinator.pendingOwnerDecisions().isEmpty, "a skipped check leaves no result")
    }
}
