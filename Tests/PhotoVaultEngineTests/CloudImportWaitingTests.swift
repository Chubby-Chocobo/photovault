import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A cloud file that cannot be read now waits; it never costs the other files their turn, and it never fails the import without a limit.
@Suite struct CloudImportWaitingTests {
    private func harness() async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        return h
    }

    private func tree(_ h: Harness) throws -> ImportFolder {
        let folder = try ImportFolder()
        let when = h.clock.now.addingTimeInterval(-3 * 86_400)
        try folder.add("a.jpg", metadata: ImportFolder.photo(at: when))
        try folder.add("b.jpg", metadata: ImportFolder.photo(at: when.addingTimeInterval(-3600)))
        return folder
    }

    private func finish(_ h: Harness, hours: Double = 1, times: Int = 5) async {
        for _ in 0..<times { h.clock.advance(by: hours * 3600); await h.settle(rounds: 3) }
    }

    // MARK: A dropped connection

    @Test func aDroppedConnectionOnOneReadDoesNotFailTheFile() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.failOnce(.inspect, SourceError.unavailable)
        let id = try await h.startCloudImport(source)
        await finish(h, hours: 0.05, times: 4)
        #expect(try h.importCounts(id) == [.imported: 2])
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func aCloudFileThatCannotBeReadForGoodFailsAtOnce() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(path: "a.jpg", SourceError.readFailed(code: 5))
        let id = try await h.startCloudImport(source)
        await finish(h, hours: 0.05, times: 3)
        #expect(try h.importCounts(id) == [.imported: 1, .failed: 1])
    }

    // MARK: One blocked group

    @Test func aFileThatNeverFitsOnTheDiskDoesNotBlockTheOthers() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setSize(of: "a.jpg", 200 * GlobalSettings.GiB)
        h.disk.set(available: 100 * GlobalSettings.GiB)
        let id = try await h.startCloudImport(source)
        await finish(h)
        let counts = try h.importCounts(id)
        #expect(counts == [.imported: 1, .pending: 1], "\(counts)")
        let row = try #require(try h.source(id))
        #expect(row.status == .scanning && row.statusReason == "diskFull")
        let snapshot = try #require(try h.read { try SnapshotBuilder.imports($0) }.first)
        #expect(snapshot.statusReason == "diskFull")

        h.disk.set(available: 500 * GlobalSettings.GiB)
        await finish(h, hours: 0.05, times: 4)
        #expect(try h.importCounts(id) == [.imported: 2])
        #expect(try h.source(id)?.status == .completed && h.source(id)?.statusReason == nil)
    }

    @Test func aFileThatIsAlwaysBusyDoesNotBlockTheOthersAndIsGivenUpAfterADay() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(path: "a.jpg", SourceError.busy)
        let id = try await h.startCloudImport(source)
        await finish(h, hours: 1, times: 5)
        #expect(try h.importCounts(id) == [.imported: 1, .pending: 1], "still retrying after five hours")
        #expect(try h.source(id)?.status == .scanning)

        await finish(h, hours: 1, times: 20)
        #expect(try h.importCounts(id) == [.imported: 1, .failed: 1])
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func aBusyFileThatRecoversIsNotGivenUp() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(path: "a.jpg", SourceError.busy)
        let id = try await h.startCloudImport(source)
        await finish(h, hours: 1, times: 12)
        source.setFailure(path: "a.jpg", nil)
        await finish(h, hours: 1, times: 2)
        #expect(try h.importCounts(id) == [.imported: 2])
    }

    // MARK: An import that is offline

    @Test func anOfflineImportIsNotProbedOnEveryPass() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setRevoked(.probe)
        let id = try await h.startCloudImport(source)
        #expect(try h.source(id)?.status == .offline)
        h.clock.advance(by: ImportHolds.signInBackoff + 1)
        await h.run()
        let before = source.probeCount
        for _ in 0..<5 { await h.run() }
        #expect(source.probeCount == before)
        h.clock.advance(by: ImportHolds.signInBackoff + 1)
        await h.run()
        #expect(source.probeCount == before + 1)
    }
}
