import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// The failure count and the time of the first failure live in the database, so relaunching the app
/// neither forgives a file that cannot be read nor keeps it waiting for ever.
@Suite struct CloudImportRelaunchTests {
    private func harness() async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        return h
    }

    private func photos(_ h: Harness, _ names: [String]) throws -> ImportFolder {
        let folder = try ImportFolder()
        let when = h.clock.now.addingTimeInterval(-3 * 86_400)
        for (index, name) in names.enumerated() {
            try folder.add(name, metadata: ImportFolder.photo(at: when.addingTimeInterval(Double(-index) * 3600)))
        }
        return folder
    }

    /// Every hour the app is closed and opened again, as on a Mac that is restarted daily.
    private func relaunchHourly(_ h: Harness, hours: Int) async throws {
        for _ in 0..<hours {
            try await h.restart()
            h.clock.advance(by: 3600)
            await h.settle(rounds: 3)
        }
    }

    private func stored(_ h: Harness, _ id: SourceID, _ path: String) throws -> (tries: Int?, first: Date?) {
        try h.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT fail_count, first_failed_at FROM import_item WHERE source_id = ? AND rel_path = ?", arguments: [id.rawValue, path])
            return (row?["fail_count"], row?["first_failed_at"])
        }
    }

    @Test func aRelaunchDoesNotResetTheCount() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg"]))
        source.setFailure(path: "a.jpg", SourceError.busy)
        let id = try await h.startCloudImport(source)
        let before = try stored(h, id, "a.jpg")
        #expect((before.tries ?? 0) >= 1 && before.first != nil)
        try await h.restart()
        h.clock.advance(by: 120)
        await h.settle(rounds: 3)
        let after = try stored(h, id, "a.jpg")
        #expect((after.tries ?? 0) > (before.tries ?? 0), "the new engine continues from the stored count")
        #expect(after.first == before.first)
    }

    @Test func aFileThatCannotBeReadIsGivenUpAcrossDailyRelaunches() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg", "c.jpg"]))
        source.setFailure(path: "b.jpg", SourceError.busy)
        let id = try await h.startCloudImport(source)
        try await relaunchHourly(h, hours: 30)
        #expect(try h.importCounts(id) == [.imported: 2, .failed: 1])
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func aFileThatIsReadAfterARelaunchClearsItsCount() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg"]))
        source.setFailure(path: "a.jpg", SourceError.busy)
        let id = try await h.startCloudImport(source)
        #expect((try stored(h, id, "a.jpg").tries ?? 0) >= 1)
        source.setFailure(path: "a.jpg", nil)
        try await h.restart()
        h.clock.advance(by: 120)
        await h.settle(rounds: 3)
        #expect(try h.importCounts(id) == [.imported: 1])
        let cleared = try stored(h, id, "a.jpg")
        #expect(cleared.tries == nil && cleared.first == nil)
    }

    @Test func aFolderWithoutTransientFailuresStoresNothing() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg"]))
        let id = try await h.startCloudImport(source)
        #expect(try h.importCounts(id) == [.imported: 2])
        let stored = try stored(h, id, "a.jpg")
        #expect(stored.tries == nil && stored.first == nil)
    }
}
