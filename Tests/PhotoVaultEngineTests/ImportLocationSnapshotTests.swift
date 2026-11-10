import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultEngine

@Suite struct ImportLocationSnapshotTests {
    @Test func aMacFolderImportStoresItsPathAndTheSnapshotCarriesIt() async throws {
        let h = try await Harness()
        try await h.baseline()
        let folder = try ImportFolder()
        let id = try await h.coordinator.startFolderImport(
            source: folder.source(), displayName: "2024", bookmark: Data([1]), locationPath: "~/Pictures/Trips/2024")
        #expect(try h.source(id)?.config.locationPaths == ["~/Pictures/Trips/2024"])
        let snapshot = try #require(try h.read { try SnapshotBuilder.imports($0) }.first)
        #expect(snapshot.location?.paths == ["~/Pictures/Trips/2024"])
    }

    @Test func aMacImportWithoutAPathHasNoLocation() async throws {
        let h = try await Harness()
        try await h.baseline()
        let folder = try ImportFolder()
        _ = try await h.coordinator.startFolderImport(source: folder.source(), displayName: "2024", bookmark: Data([1]))
        let snapshot = try #require(try h.read { try SnapshotBuilder.imports($0) }.first)
        #expect(snapshot.location == nil)
    }

    @Test func aDropboxImportShowsItsRootFolder() async throws {
        let h = try await Harness.organized()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let folder = try ImportFolder()
        _ = try await h.coordinator.startImport(
            source: FakeCloudSource(folder), kind: .dropbox, displayName: "2024",
            config: SourceConfig(account: "a@b.c", remoteItems: ["/Camera Uploads/2024"]))
        let snapshot = try #require(try h.read { try SnapshotBuilder.imports($0) }.first)
        #expect(snapshot.location?.paths == ["/Camera Uploads/2024"])
    }
}
