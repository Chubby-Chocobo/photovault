import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A cloud import's sign-in is needed only while its files still have to be read. Once the import is closed and
/// every upload of its files has finished, the engine names it as ready to let go of its grant.
@Suite struct CloudImportGrantReleaseTests {
    private func harness() async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        return h
    }

    private func seed(_ h: Harness, status: SourceStatus, kind: SourceKind = .googleDrive, withJob: Bool = true) async throws -> FakeContentSource {
        let source = FakeContentSource()
        _ = try await h.seedImported("one", source: source, status: status, destinations: withJob ? [.googleDrive] : [])
        try h.write { db in try db.execute(sql: "UPDATE source SET kind = ? WHERE id = ?", arguments: [kind.rawValue, source.id.rawValue]) }
        return source
    }

    private func setJobs(_ h: Harness, _ state: JobState) throws {
        try h.write { db in try db.execute(sql: "UPDATE upload_job SET state = ?", arguments: [state.rawValue]) }
    }

    @Test func aClosedImportWithAllUploadsDoneIsReleased() async throws {
        let h = try await harness()
        let source = try await seed(h, status: .completed)
        try setJobs(h, .done)
        #expect(try await h.coordinator.closedImportsReadyToRelease() == [source.id])
    }

    @Test func aCancelledImportIsReleasedLikeAFinishedOne() async throws {
        let h = try await harness()
        let source = try await seed(h, status: .cancelled)
        try setJobs(h, .cancelled)
        #expect(try await h.coordinator.closedImportsReadyToRelease() == [source.id])
    }

    @Test(arguments: [JobState.pending, .uploading, .deferred])
    func anUploadStillToComeKeepsTheGrant(state: JobState) async throws {
        let h = try await harness()
        _ = try await seed(h, status: .completed)
        try setJobs(h, state)
        #expect(try await h.coordinator.closedImportsReadyToRelease().isEmpty)
    }

    @Test func anOpenImportKeepsTheGrant() async throws {
        let h = try await harness()
        for status in [SourceStatus.scanning, .importing, .offline] {
            let h = try await harness()
            _ = try await seed(h, status: status)
            try setJobs(h, .done)
            #expect(try await h.coordinator.closedImportsReadyToRelease().isEmpty, "\(status)")
        }
    }

    @Test func aMacFolderIsNeverListed() async throws {
        let h = try await harness()
        _ = try await seed(h, status: .completed, kind: .localFolder)
        try setJobs(h, .done)
        #expect(try await h.coordinator.closedImportsReadyToRelease().isEmpty)
    }

    @Test func aDestinationAddedLaterTurnsTheImportBackIntoOneInUse() async throws {
        let h = try await harness()
        let source = try await seed(h, status: .completed, withJob: false)
        #expect(try await h.coordinator.closedImportsReadyToRelease() == [source.id])
        try h.write { db in
            let key = try #require(try String.fetchOne(db, sql: "SELECT asset_key FROM asset WHERE source_id = ?", arguments: [source.id.rawValue]).flatMap(AssetKey.init(rawValue:)))
            var job = UploadJob(destinationId: .googleDrive, assetKey: key, resType: .photo, origin: .destinationBackfill, targetGen: 1, updatedAt: h.clock.now)
            job.state = .pending
            try JobRepository.save(db, &job)
        }
        #expect(try await h.coordinator.closedImportsReadyToRelease().isEmpty)
    }

    @Test func releasingTheAdapterMakesLaterExportsAskForSignIn() async throws {
        let h = try await harness()
        let source = try await seed(h, status: .completed, withJob: false)
        await h.coordinator.releaseImportSource(source.id)
        #expect(await h.sources.content(for: source.id) == nil)
        // A destination added later finds no adapter: the import is marked as needing sign-in.
        try h.write { db in
            let key = try #require(try String.fetchOne(db, sql: "SELECT asset_key FROM asset WHERE source_id = ?", arguments: [source.id.rawValue]).flatMap(AssetKey.init(rawValue:)))
            var job = UploadJob(destinationId: .googleDrive, assetKey: key, resType: .photo, origin: .destinationBackfill, targetGen: 1, updatedAt: h.clock.now)
            try JobRepository.save(db, &job)
        }
        await h.run()
        #expect(try h.source(source.id)?.statusReason == "signInRequired")
    }
}

/// The activity line of an import that read nothing says so.
@Suite struct ImportCompletionSummaryTests {
    func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    @Test func anImportThatFoundNothingSaysSo() {
        vi { #expect(ImportCompletion.summaryText([:], cancelled: false) == "Nhập xong 1 thư mục nhưng không có ảnh hay video nào mà app đọc được") }
        en { #expect(ImportCompletion.summaryText([:], cancelled: false) == "Folder import finished, but it had no photos or videos the app could read") }
    }

    @Test func aCancelledEmptyImportStaysACancel() {
        en { #expect(ImportCompletion.summaryText([:], cancelled: true).hasPrefix("Folder import cancelled")) }
    }

    @Test func anImportWithFilesKeepsTheCountsLine() {
        en { #expect(ImportCompletion.summaryText([.imported: 2], cancelled: false) == "Folder import finished: 2 new, 0 already backed up, 0 skipped, 0 failed") }
    }
}
