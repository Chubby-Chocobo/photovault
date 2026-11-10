import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

@Suite struct RemoteIdIndexTests {
    private struct Offline: Error {}

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("remote-ids-\(UUID().uuidString)/map.json")
    }

    @Test func aRelistThatFailedDoesNotMakeAnUnknownPathMissingForAWhile() async throws {
        let index = RemoteIdIndex(file: file(), relistInterval: .seconds(60))
        await #expect(throws: Offline.self) { _ = try await index.resolve("a.jpg") { throw Offline() } }
        // A second caller right after must ask again instead of being told the file is gone.
        let id = try await index.resolve("a.jpg") { ["a.jpg": "ID-A"] }
        #expect(id == "ID-A")
    }

    @Test func aRelistThatWorkedKeepsAnUnknownPathMissingWithinTheInterval() async throws {
        let index = RemoteIdIndex(file: file(), relistInterval: .seconds(60))
        #expect(try await index.resolve("a.jpg") { [:] } == nil)
        #expect(try await index.resolve("a.jpg") { ["a.jpg": "ID-A"] } == nil, "no second listing so soon")
    }

    @Test func aFailedWriteIsRetriedByTheNextMergeEvenWhenNothingIsNew() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-ids-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A directory where the map file belongs makes the write fail.
        let blocked = directory.appendingPathComponent("map.json")
        try FileManager.default.createDirectory(at: blocked.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let index = RemoteIdIndex(file: blocked)
        var failed = false
        do { try await index.merge(["a.jpg": "ID-A"]) } catch { failed = true }
        #expect(failed)

        try FileManager.default.removeItem(at: blocked)
        try await index.merge(["a.jpg": "ID-A"])
        let reopened = RemoteIdIndex(file: blocked)
        #expect(await reopened.lookup("a.jpg") == "ID-A", "the map on disk caught up with memory")
    }
}
