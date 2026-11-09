import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct CloudImportTests {
    private func harness() async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        return h
    }

    private func when(_ h: Harness, daysAgo: Double = 3) -> Date { h.clock.now.addingTimeInterval(-daysAgo * 86_400) }

    private func tree(_ h: Harness) throws -> ImportFolder {
        let folder = try ImportFolder()
        try folder.add("a.jpg", metadata: ImportFolder.photo(at: when(h)))
        try folder.add("sub/b.jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: 4)))
        try folder.add("sub/copy-of-b.jpg", "bytes-of-sub/b.jpg", metadata: ImportFolder.photo(at: when(h, daysAgo: 4)))
        try folder.add("sub/IMG_1.AAE", "plist")
        return folder
    }

    private struct Outcome: Equatable {
        var keys: [String]
        var paths: [String]
        var counts: [ImportItemState: Int]
    }

    private func outcome(_ h: Harness, _ id: SourceID) async throws -> Outcome {
        let keys = try h.assets(of: id).map(\.assetKey.rawValue).sorted()
        var paths: [String] = []
        for file in await h.drive.files { paths.append(await h.drive.path(of: file.id)) }
        return Outcome(keys: keys, paths: paths.sorted(), counts: try h.importCounts(id))
    }

    // MARK: Parity

    @Test func aCloudAdapterGivesTheSameResultAsAMacFolder() async throws {
        let mac = try await harness()
        let macId = try await mac.startImport(try tree(mac))
        let cloud = try await harness()
        let cloudFolder = try tree(cloud)
        let cloudId = try await cloud.startCloudImport(FakeCloudSource(cloudFolder))
        let expected = try await outcome(mac, macId)
        #expect(expected.keys.count == 2 && expected.counts == [.imported: 2, .duplicate: 1, .unsupported: 1], "\(expected)")
        #expect(try await outcome(cloud, cloudId) == expected)
        #expect(try cloud.source(cloudId)?.status == .completed)
    }

    @Test func theRowKeepsItsKindAndAccountAndTheSnapshotCarriesThem() async throws {
        let h = try await harness()
        let id = try await h.startCloudImport(FakeCloudSource(try tree(h)), kind: .googleDrive)
        let row = try #require(try h.source(id))
        #expect(row.kind == .googleDrive && row.config.account == "someone@example.com" && row.config.remoteItems == [""])
        let snapshot = try #require(try h.read { try SnapshotBuilder.imports($0) }.first)
        #expect(snapshot.kind == .googleDrive && snapshot.account == "someone@example.com" && snapshot.statusReason == nil)
    }

    @Test func theSidecarNamesTheCloudKind() async throws {
        let h = try await Harness.organized()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let folder = try ImportFolder()
        try folder.add("sub/a.jpg", metadata: ImportFolder.photo(at: when(h)))
        let id = try await h.startCloudImport(FakeCloudSource(folder), kind: .dropbox)
        let key = try #require(try h.assets(of: id).first?.assetKey)
        let json = try h.read { db -> String in
            let asset = try #require(try AssetRepository.fetch(db, key: key))
            let file = try #require(try SidecarFactory.build(
                db, asset: asset, destinationId: .googleDrive, type: .sidecarJson, settings: GlobalSettings(), timeZone: utc,
                nameBuilder: NameStemBuilder(timeZone: utc, utiResolver: FakeUTIResolver())))
            return String(decoding: file.data, as: UTF8.self)
        }
        #expect(json.contains("\"kind\": \"dropbox\""), "\(json)")
    }

    // MARK: Revoked access

    @Test func aRevokedListingHoldsTheImportForSignInAndResumesWhenTheAdapterAnswers() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setRevoked(.list)
        let id = try await h.startCloudImport(source)
        #expect(try h.source(id)?.status == .offline && h.source(id)?.statusReason == "signInRequired")
        #expect(try h.read { try SnapshotBuilder.imports($0) }.first?.statusReason == "signInRequired")
        source.setRevoked([])
        for _ in 0..<4 { h.clock.advance(by: 120); await h.settle(rounds: 3) }
        #expect(try h.source(id)?.status == .completed && h.source(id)?.statusReason == nil)
        #expect(try h.importCounts(id)[.imported] == 2)
    }

    @Test func aRevokedProbeOfAnOpenImportStaysHeldUntilItAnswers() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        let id = try await h.startCloudImport(source, settle: 1)
        source.setRevoked(.probe)
        h.clock.advance(by: 120)
        try h.write { db in try SourceRepository.setStatus(db, id: id, status: .scanning, reason: nil, now: h.clock.now) }
        await h.settle(rounds: 2)
        #expect(try h.source(id)?.status == .offline && h.source(id)?.statusReason == "signInRequired")
        source.setRevoked([])
        for _ in 0..<4 { h.clock.advance(by: 120); await h.settle(rounds: 3) }
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func aRevokedInspectHoldsTheImportForSignIn() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try tree(h))
        source.setRevoked(.inspect)
        let id = try await h.startCloudImport(source)
        #expect(try h.source(id)?.status == .offline && h.source(id)?.statusReason == "signInRequired")
        #expect(try h.importCounts(id)[.imported] == nil)
    }

    @Test func aRevokedExportOfAClosedImportSkipsTheJobWithoutAnError() async throws {
        let h = try await harness()
        let source = FakeContentSource()
        _ = try await h.seedImported("done", source: source, status: .completed)
        source.setRevoked(true)
        for _ in 0..<2 { await h.run(); h.clock.advance(by: 120) }
        #expect(try h.jobs(.skipped).count == 1)
    }

    @Test func aRevokedExportOfAnOpenImportHoldsItForSignIn() async throws {
        let h = try await harness()
        let source = FakeContentSource()
        let id = source.id
        _ = try await h.seedImported("open", source: source, status: .importing)
        source.setRevoked(true)
        await h.run()
        #expect(try h.source(id)?.status == .offline && h.source(id)?.statusReason == "signInRequired")
        #expect(try h.jobs(.skipped).isEmpty)
        #expect(try h.jobs(.pending).count == 1)
    }

    @Test func aFinishedCloudImportWithoutAnAdapterIsStillWaitedForNotLost() async throws {
        let h = try await harness()
        let source = FakeContentSource()
        _ = try await h.seedImported("kept", source: source, status: .completed)
        try h.write { db in
            try db.execute(sql: "UPDATE source SET kind = 'dropbox' WHERE id = ?", arguments: [source.id.rawValue])
        }
        source.setOnline(false)
        for _ in 0..<2 { await h.run(); h.clock.advance(by: 120) }
        #expect(try h.jobs(.skipped).isEmpty && h.jobs(.pending).count == 1)
    }
}
