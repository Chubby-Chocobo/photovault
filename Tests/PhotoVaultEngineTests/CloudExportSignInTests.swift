import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A finished cloud import whose grant is gone asks once, keeps its files waiting and picks up right after sign-in.
@Suite struct CloudExportSignInTests {
    private func harness() async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        return h
    }

    private func finishedCloudImport(_ h: Harness, files: Int) async throws -> (FakeContentSource, [AssetKey]) {
        let source = FakeContentSource()
        var keys: [AssetKey] = []
        for index in 0..<files { keys.append(try await h.seedImported("file\(index)", source: source, status: .completed)) }
        try h.write { db in try db.execute(sql: "UPDATE source SET kind = 'dropbox' WHERE id = ?", arguments: [source.id.rawValue]) }
        return (source, keys)
    }

    private func retryTimes(_ h: Harness) throws -> [Date?] {
        try h.read { db in try Date?.fetchAll(db, sql: "SELECT next_export_attempt_at FROM resource ORDER BY asset_key") }
    }

    @Test func oneRevokedExportHoldsTheOtherFilesOfTheSameImport() async throws {
        let h = try await harness()
        let (source, _) = try await finishedCloudImport(h, files: 4)
        source.setRevoked(true)
        await h.run()
        let times = try retryTimes(h)
        #expect(times.count == 4 && times.allSatisfy { ($0 ?? .distantPast) > h.clock.now }, "\(times)")
        #expect(try h.source(source.id)?.statusReason == "signInRequired")
    }

    @Test func aRevokedImportAsksTheProviderOnceNotOncePerFile() async throws {
        let h = try await harness()
        let (source, _) = try await finishedCloudImport(h, files: 30)
        let counting = CountingContentSource(source)
        await h.sources.add(counting)
        source.setRevoked(true)
        await h.run()
        #expect(counting.calls <= h.env.tuning.maxConcurrentExports, "asked \(counting.calls) times")
        let before = counting.calls
        await h.run()
        #expect(counting.calls == before, "nothing more is asked within the hour")
    }

    @Test func signingInAgainLetsTheWaitingFilesRunOnTheNextCycle() async throws {
        let h = try await harness()
        let (source, _) = try await finishedCloudImport(h, files: 3)
        source.setRevoked(true)
        await h.run()
        source.setRevoked(false)
        try await h.coordinator.resumeImportAfterSignIn(source.id)
        #expect(try retryTimes(h).allSatisfy { $0 == nil })
        await h.settle(rounds: 3)
        #expect(try h.jobs(.done).count == 3, "no clock advance was needed")
    }

    @Test func aWaitingExportDropsAnErrorRecordedBefore() async throws {
        let h = try await harness()
        let (source, keys) = try await finishedCloudImport(h, files: 1)
        try h.write { db in try ResourceRepository.noteExportError(db, key: keys[0], type: .photo, message: "source: readFailed") }
        source.setRevoked(true)
        await h.run()
        let errors = try h.read { db in try ResourceRepository.fetchAll(db, key: keys[0]).compactMap(\.lastError) }
        #expect(errors.isEmpty)
    }
}
