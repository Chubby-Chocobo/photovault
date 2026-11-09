import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Cloud adapters throttle, fail in odd ways and lose their grant; none of that may lose a file or stop other jobs.
@Suite struct CloudImportResilienceTests {
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

    private func finish(_ h: Harness) async {
        for _ in 0..<4 { h.clock.advance(by: 120); await h.settle(rounds: 3) }
    }

    private func asCloud(_ source: FakeContentSource, in h: Harness) throws {
        try h.write { db in try db.execute(sql: "UPDATE source SET kind = 'dropbox' WHERE id = ?", arguments: [source.id.rawValue]) }
    }

    // MARK: Throttling

    @Test func aThrottledReadKeepsEveryFilePendingAndTheJobOnline() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(.inspect, SourceError.busy)
        let id = try await h.startCloudImport(source)
        let row = try #require(try h.source(id))
        #expect(row.status == .scanning && row.statusReason == nil)
        #expect(try h.importCounts(id)[.pending] == 2 && h.importCounts(id)[.failed] == nil)
        source.setFailure(.inspect, nil)
        await finish(h)
        #expect(try h.source(id)?.status == .completed)
        #expect(try h.importCounts(id)[.imported] == 2)
    }

    @Test func aThrottledReadWaitsOutTheCooldownBeforeTryingAgain() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(.inspect, SourceError.busy)
        let id = try await h.startCloudImport(source, settle: 0)
        await h.run()
        source.setFailure(.inspect, nil)
        await h.run()
        #expect(try h.importCounts(id)[.pending] == 2, "still cooling down")
        h.clock.advance(by: ImportHolds.backoff + 1)
        await h.settle(rounds: 3)
        #expect(try h.importCounts(id)[.imported] == 2)
    }

    @Test func aThrottledListingAndProbeStayOnlineToo() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(.list, SourceError.busy)
        let id = try await h.startCloudImport(source)
        #expect(try h.source(id)?.status == .scanning && h.source(id)?.listedAt == nil)
        source.setFailure(.list, nil)
        source.setFailure(.probe, SourceError.busy)
        await finish(h)
        #expect(try h.source(id)?.status == .scanning, "probe is throttled")
        source.setFailure(.probe, nil)
        await finish(h)
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func aThrottledExportOfAnOpenImportRetriesWithoutCostOrHold() async throws {
        let h = try await harness()
        let source = FakeContentSource()
        let id = source.id
        let key = try await h.seedImported("busy", source: source, status: .importing)
        source.setFailure(SourceError.busy)
        await h.run()
        #expect(try h.source(id)?.status == .importing && h.source(id)?.statusReason == nil)
        #expect(try h.jobs(.pending).count == 1)
        let resource = try h.read { db in try ResourceRepository.fetchAll(db, key: key) }
        #expect(resource.map(\.exportAttempts) == [0] && resource.compactMap(\.lastError).isEmpty)
        source.setFailure(nil)
        for _ in 0..<2 { h.clock.advance(by: 3600); await h.run() }
        #expect(try h.jobs(.done).count == 1)
    }

    // MARK: Misbehaving adapters

    @Test func anAdapterThatThrowsAnUnknownErrorHoldsItsJobWithoutStoppingTheCycle() async throws {
        let h = try await harness()
        for call: FakeCloudSource.Revoked in [.probe, .list, .inspect] {
            let source = FakeCloudSource(try tree(h))
            source.setFailure(call, URLError(.timedOut))
            let id = try await coordinatorStart(h, source)
            let outcome = await h.run()
            guard case .completed = outcome else { Issue.record("cycle did not complete for \(call): \(outcome)"); continue }
            #expect(try h.source(id)?.status == .offline && h.source(id)?.statusReason == "unavailable", "\(call)")
            #expect(try h.importCounts(id)[.failed] == nil, "\(call)")
        }
    }

    private func coordinatorStart(_ h: Harness, _ source: FakeCloudSource) async throws -> SourceID {
        let id = try await h.coordinator.startImport(
            source: source, kind: .dropbox, displayName: "Trip", config: SourceConfig(account: "someone@example.com", remoteItems: [""]))
        await h.settle(rounds: 2)
        return id
    }

    @Test func anExportAdapterThatThrowsAnUnknownErrorHoldsItsJob() async throws {
        let h = try await harness()
        let source = FakeContentSource()
        let id = source.id
        _ = try await h.seedImported("odd", source: source, status: .importing)
        source.setFailure(URLError(.badServerResponse))
        let outcome = await h.run()
        guard case .completed = outcome else { Issue.record("cycle did not complete: \(outcome)"); return }
        #expect(try h.source(id)?.status == .offline && h.source(id)?.statusReason == "unavailable")
        #expect(try h.jobs(.pending).count == 1 && h.jobs(.skipped).isEmpty)
    }

    // MARK: Disk

    @Test func aCloudDownloadDoesNotStartWhenItWouldEatTheReserve() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        h.disk.set(available: 1 << 20)
        let id = try await h.startCloudImport(source)
        #expect(try h.source(id)?.status == .scanning && h.source(id)?.statusReason == nil)
        #expect(try h.importCounts(id)[.pending] == 2 && h.importCounts(id)[.failed] == nil)
        h.disk.set(available: 500 * GlobalSettings.GiB)
        await finish(h)
        #expect(try h.importCounts(id)[.imported] == 2)
    }

    // MARK: Sign-in on a finished import

    @Test func aRevokedExportOfAFinishedCloudImportWaitsAndAsksForSignIn() async throws {
        let h = try await harness()
        let source = FakeContentSource()
        let id = source.id
        let key = try await h.seedImported("done", source: source, status: .completed)
        try asCloud(source, in: h)
        source.setRevoked(true)
        for _ in 0..<2 { await h.run(); h.clock.advance(by: 3600 + 1) }
        #expect(try h.jobs(.skipped).isEmpty && h.jobs(.pending).count == 1)
        #expect(try h.source(id)?.status == .completed && h.source(id)?.statusReason == "signInRequired")
        let snapshot = try #require(try h.read { try SnapshotBuilder.imports($0) }.first)
        #expect(snapshot.statusReason == "signInRequired" && snapshot.status == .completed)
        let errors = try h.read { db in try ResourceRepository.fetchAll(db, key: key).compactMap(\.lastError) }
        #expect(errors.isEmpty, "waiting is not failing")

        source.setRevoked(false)
        try await h.coordinator.resumeImportAfterSignIn(id)
        #expect(try h.source(id)?.statusReason == nil)
        for _ in 0..<2 { await h.run(); h.clock.advance(by: 3600 + 1) }
        #expect(try h.jobs(.done).count == 1)
    }

    @Test func aFinishedCloudImportWithoutAnAdapterAsksForSignIn() async throws {
        let h = try await harness()
        let source = FakeContentSource()
        let id = source.id
        _ = try await h.seedImported("kept", source: source, status: .completed)
        try asCloud(source, in: h)
        await h.env.sources.remove(id)
        await h.run()
        #expect(try h.source(id)?.statusReason == "signInRequired")
        #expect(try h.jobs(.pending).count == 1)
    }

    @Test func aFileGoneWhileTheSourceAnswersIsStillSkipped() async throws {
        let h = try await harness()
        let source = FakeContentSource()
        _ = try await h.seedImported("gone", source: source, status: .completed)
        try asCloud(source, in: h)
        source.removeAll()
        await h.run()
        #expect(try h.jobs(.skipped).count == 1)
        #expect(try h.source(source.id)?.statusReason == nil)
    }

    @Test func theSignInCommandResumesAHeldJobBeforeTheCooldownEnds() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setRevoked(.list)
        let id = try await h.startCloudImport(source, settle: 1)
        #expect(try h.source(id)?.statusReason == "signInRequired")
        source.setRevoked([])
        try await h.coordinator.resumeImportAfterSignIn(id)
        #expect(try h.source(id)?.status == .scanning && h.source(id)?.statusReason == nil)
        await h.run()
        await h.run()
        #expect(try h.importCounts(id)[.imported] == 2, "no clock advance was needed")
    }
}
