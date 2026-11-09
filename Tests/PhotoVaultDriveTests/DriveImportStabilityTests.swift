import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

@Suite struct DriveImportStabilityTests {
    private func inspect(_ source: DriveImportSource, _ path: String) async throws -> InspectedFile {
        try await source.inspect(relativePath: path, uti: "public.jpeg", mediaType: .image, control: ExportControl())
    }

    // MARK: Stable paths

    @Test func aPathKeepsItsFileAfterARelaunchEvenWhenASiblingWithASmallerIdAppears() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "F", name: "Dir", mime: DriveMime.folder))
        rig.stub.add(.init(id: "m", name: "IMG_1.jpg", parent: "F", content: Data("first".utf8)))
        rig.stub.add(.init(id: "z", name: "IMG_1.jpg", parent: "F", content: Data("second".utf8)))
        let before = try await rig.source(["F"]).listFiles().map(\.relativePath)
        #expect(before == ["Dir/IMG_1 (2).jpg", "Dir/IMG_1.jpg"])

        rig.stub.add(.init(id: "a", name: "IMG_1.jpg", parent: "F", content: Data("newcomer".utf8)))
        let relaunched = rig.source(["F"])
        #expect(try await inspect(relaunched, "Dir/IMG_1.jpg").sha256 == sha(Data("first".utf8)))
        #expect(try await inspect(relaunched, "Dir/IMG_1 (2).jpg").sha256 == sha(Data("second".utf8)))
        #expect(rig.stub.listingRequests == 1, "the saved map answered without a new listing")
    }

    @Test func aSecondListingNeverMovesAPathToAnotherFile() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "m", name: "IMG_1.jpg", content: Data("first".utf8)))
        let source = rig.source(["m", "a"])
        #expect(try await source.listFiles().map(\.relativePath) == ["IMG_1.jpg"])
        rig.stub.add(.init(id: "a", name: "IMG_1.jpg", content: Data("newcomer".utf8)))
        let again = try await source.listFiles().map(\.relativePath)
        #expect(again == ["IMG_1.jpg"], "the newcomer is not part of this import")
        #expect(try await inspect(source, "IMG_1.jpg").sha256 == sha(Data("first".utf8)))
    }

    @Test func theMapIsOnDiskBeforeListingReturns() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg", content: Data("x".utf8)))
        _ = try await rig.source(["A"]).listFiles()
        let data = try Data(contentsOf: rig.state.appendingPathComponent("remote-ids.json"))
        #expect(String(decoding: data, as: UTF8.self).contains("\"a.jpg\""))
    }

    @Test func concurrentReadsAfterARelaunchShareOneListing() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "F", name: "D", mime: DriveMime.folder))
        for i in 1...4 { rig.stub.add(.init(id: "a\(i)", name: "p\(i).jpg", parent: "F", content: Data("c\(i)".utf8))) }
        let fresh = rig.source(["F"])
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 1...4 { group.addTask { try await self.inspect(fresh, "D/p\(i).jpg").sha256 } }
            var hashes = Set<String>()
            for try await hash in group { hashes.insert(hash) }
            #expect(hashes.count == 4)
        }
        #expect(rig.stub.listingRequests == 1)
    }

    @Test func aMapThatCannotBeWrittenFailsTheListingWithoutAnUnknownError() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg"))
        try Data().write(to: rig.state.deletingLastPathComponent().appendingPathComponent("state"))
        await #expect(throws: SourceError.self) { _ = try await rig.source(["A"]).listFiles() }
    }

    @Test func aScratchFolderThatCannotBeMadeIsAReadFailure() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg", content: Data("x".utf8)))
        let source = rig.source(["A"])
        _ = try await source.listFiles()
        try Data().write(to: rig.scratch.deletingLastPathComponent().appendingPathComponent("scratch"))
        do { _ = try await inspect(source, "a.jpg"); Issue.record("expected a failure") } catch let error as SourceError {
            guard case .readFailed = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    // MARK: Items Drive refuses

    @Test func anUnreadablePickDoesNotHoldTheJob() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg", content: Data("x".utf8)))
        rig.stub.add(.init(id: "B", name: "b.jpg", content: Data("y".utf8)))
        rig.stub.fail("X", with: .json(403, ["error": ["errors": [["reason": "appNotAuthorizedToFile"]]]]))
        let source = rig.source(["X", "A", "B"])
        try await source.probe()
        #expect(try await source.listFiles().map(\.relativePath) == ["a.jpg", "b.jpg"])
    }

    @Test func aFolderThatCannotBeReadIsSkippedNotFatal() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "F", name: "D", mime: DriveMime.folder))
        rig.stub.add(.init(id: "A", name: "a.jpg", content: Data("x".utf8)))
        rig.stub.failListing(of: "F", with: .json(403, ["error": ["errors": [["reason": "forbidden"]]]]))
        #expect(try await rig.source(["F", "A"]).listFiles().map(\.relativePath) == ["a.jpg"])
    }

    @Test func throttlingWhileListingOrProbingIsBusyNotUnavailable() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg"))
        rig.stub.fail("A", with: .json(429, [:]))
        let source = rig.source(["A"])
        await #expect(throws: SourceError.busy) { try await source.probe() }
        await #expect(throws: SourceError.busy) { _ = try await source.listFiles() }
    }

    @Test func importCallsReachSharedDrivesToo() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "F", name: "D", mime: DriveMime.folder))
        rig.stub.add(.init(id: "A", name: "a.jpg", parent: "F", content: Data("x".utf8)))
        let source = rig.source(["F"])
        try await source.probe()
        _ = try await source.listFiles()
        _ = try await inspect(source, "D/a.jpg")
        let urls = rig.stub.requests.compactMap(\.url)
        #expect(urls.count >= 4)
        for url in urls {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.contains(URLQueryItem(name: "supportsAllDrives", value: "true")), "\(url.path)")
            if url.path == "/drive/v3/files" { #expect(items.contains(URLQueryItem(name: "includeItemsFromAllDrives", value: "true"))) }
        }
    }
}
