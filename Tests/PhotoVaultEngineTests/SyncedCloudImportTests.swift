import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A Mac-folder import that reads Google Drive's or Dropbox's synced folder: online-only files are downloaded by the
/// first read, which can fail for a while and can fill the disk. A plain Mac or NAS folder keeps its rules.
@Suite struct SyncedCloudImportTests {
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

    private func start(_ source: FakeCloudSource, _ h: Harness, synced: SyncedCloudProvider?, settle: Int = 6) async throws -> SourceID {
        let id = try await h.coordinator.startImport(
            source: source, kind: .localFolder, displayName: "Trip", config: SourceConfig(syncedProvider: synced))
        await h.settle(rounds: settle)
        return id
    }

    static let transient: [Int32] = [EIO, ETIMEDOUT, ECANCELED, EDEADLK, EAGAIN, ENETDOWN, ENETUNREACH, ENOTCONN, EHOSTUNREACH]

    @Test(arguments: SyncedCloudImportTests.transient)
    func aDownloadThatFailsForNowWaitsAndIsRetried(code: Int32) async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(path: "a.jpg", SourceError.readFailed(code: Int(code)))
        let id = try await start(source, h, synced: .googleDrive)
        #expect(try h.importCounts(id)[.failed] == nil, "errno \(code)")
        #expect(try h.importCounts(id)[.imported] == 1 && h.importCounts(id)[.pending] == 1)
        #expect(try h.source(id)?.status == .scanning)
        source.setFailure(path: "a.jpg", nil)
        for _ in 0..<4 { h.clock.advance(by: 120); await h.settle(rounds: 3) }
        #expect(try h.importCounts(id)[.imported] == 2)
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func aPlainFolderStillFailsAFileThatCannotBeRead() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(path: "a.jpg", SourceError.readFailed(code: Int(EIO)))
        let id = try await start(source, h, synced: nil)
        #expect(try h.importCounts(id)[.failed] == 1 && h.importCounts(id)[.imported] == 1)
    }

    @Test func anErrorThatIsNotTransientStillFailsTheFile() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(path: "a.jpg", SourceError.readFailed(code: Int(EACCES)))
        let id = try await start(source, h, synced: .dropbox)
        #expect(try h.importCounts(id)[.failed] == 1 && h.importCounts(id)[.imported] == 1)
    }

    @Test func aFileThatNeverDownloadsIsGivenUpAfterADay() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setFailure(path: "a.jpg", SourceError.readFailed(code: Int(ETIMEDOUT)))
        let id = try await start(source, h, synced: .googleDrive)
        for _ in 0..<60 {
            h.clock.advance(by: 3600)
            await h.settle(rounds: 2)
            if try h.source(id)?.status == .completed { break }
        }
        #expect(try h.source(id)?.status == .completed)
        #expect(try h.importCounts(id)[.failed] == 1 && h.importCounts(id)[.imported] == 1)
    }

    @Test func aSyncedFolderWaitsForDiskRoomBeforeReadingFiles() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        h.disk.set(available: 1 << 20)
        let id = try await start(source, h, synced: .googleDrive)
        #expect(try h.source(id)?.status == .scanning && h.source(id)?.statusReason == "diskFull")
        #expect(try h.importCounts(id)[.pending] == 2 && h.importCounts(id)[.failed] == nil)
        h.disk.set(available: 500 * GlobalSettings.GiB)
        for _ in 0..<4 { h.clock.advance(by: 120); await h.settle(rounds: 3) }
        #expect(try h.importCounts(id)[.imported] == 2)
    }

    @Test func aPlainFolderDoesNotWaitForDiskRoom() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        h.disk.set(available: 1 << 20)
        let id = try await start(source, h, synced: nil)
        #expect(try h.source(id)?.statusReason != "diskFull")
        #expect(try h.importCounts(id)[.imported] == 2)
    }

    @Test func theSnapshotCarriesTheSyncedProvider() async throws {
        let h = try await harness()
        let synced = try await start(FakeCloudSource(try tree(h)), h, synced: .dropbox)
        let plain = try await start(FakeCloudSource(try tree(h)), h, synced: nil)
        let rows = try h.read { try SnapshotBuilder.imports($0) }
        #expect(rows.first { $0.id == synced }?.syncedProvider == .dropbox)
        #expect(rows.first { $0.id == plain }?.syncedProvider == nil)
    }
}
