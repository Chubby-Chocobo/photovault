import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultLocal

@Suite struct LocalMetadataTests {
    private func marker(_ id: DestinationID, at seconds: TimeInterval = 1_700_000_000) -> DestinationMarker {
        DestinationMarker(id: id, createdAt: Date(timeIntervalSince1970: seconds), archiveTimezone: "Asia/Ho_Chi_Minh")
    }

    @Test func markerRoundTripAndNeverOverwritten() async throws {
        let fx = try LocalFixture()
        #expect(try await fx.destination.readMarker() == nil)
        let ours = marker(fx.destination.id)
        #expect(try await fx.destination.writeMarker(ours) == ours)
        #expect(try await fx.destination.readMarker() == ours)
        let json = try fx.text(".photovault/destination.json")
        #expect(json.contains("\"schema\" : 1") && json.contains("archiveTimezone"))

        // Same id again keeps the original (createdAt unchanged).
        let again = try await fx.destination.writeMarker(marker(fx.destination.id, at: 1_800_000_000))
        #expect(again == ours)

        let other = LocalFolderDestination(id: .local(), root: PlainURLRoot(fx.root))
        let foreign = marker(other.id)
        #expect(await expectError(.foreignFile) { _ = try await other.writeMarker(foreign) })
        #expect(try await fx.destination.readMarker() == ours)
        #expect(try fx.names(".photovault/tmp").isEmpty)
    }

    @Test func corruptMarkerIsNeverReplaced() async throws {
        let fx = try LocalFixture()
        try FileManager.default.createDirectory(at: fx.root.appendingPathComponent(".photovault"), withIntermediateDirectories: true)
        try fx.write(".photovault/destination.json", "{ broken")
        #expect(await expectError(.foreignFile) { _ = try await fx.destination.readMarker() })
        #expect(await expectError(.foreignFile) { _ = try await fx.destination.writeMarker(marker(fx.destination.id)) })
        #expect(try fx.text(".photovault/destination.json") == "{ broken")
    }

    // MARK: Locks

    @Test func writeLockExcludesReadersBelowIt() async {
        let locks = FolderLockManager()
        let reader1 = await locks.acquire("a/b", write: false)
        let reader2 = await locks.acquire("a/b", write: false)   // readers share
        let events = EventLog()
        let writer = Task {
            let token = await locks.acquire("a", write: true)
            await events.add("writer")
            await locks.release(token)
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await events.items.isEmpty)
        let late = Task {
            let token = await locks.acquire("a/c", write: false)   // queued behind the waiting writer
            await events.add("late reader")
            await locks.release(token)
        }
        let sibling = await locks.acquire("z", write: false)       // unrelated folder is not blocked
        await locks.release(sibling)
        await locks.release(reader1)
        await locks.release(reader2)
        await writer.value
        await late.value
        #expect(await events.items == ["writer", "late reader"])
    }
}

actor EventLog {
    private(set) var items: [String] = []
    func add(_ item: String) { items.append(item) }
}

@Suite struct LocalSmallFileReadTests {
    @Test func readsSmallFilesAndRefusesLargeOnes() async throws {
        let fx = try LocalFixture()
        try FileManager.default.createDirectory(at: fx.root.appendingPathComponent("2024/2024-05"), withIntermediateDirectories: true)
        try fx.write("2024/2024-05/IMG_0001.json", "{\"schema\":1}")
        #expect(try await fx.destination.readSmallFile(remoteId: "2024/2024-05/IMG_0001.json") == Data("{\"schema\":1}".utf8))
        #expect(try await fx.destination.readSmallFile(remoteId: "2024/2024-05/missing.json") == nil)
        #expect(try await fx.destination.readSmallFile(remoteId: "2025/none.json") == nil)
        await #expect(throws: DestinationError.self) {
            _ = try await fx.destination.readSmallFile(remoteId: "2024/2024-05/IMG_0001.json", maxBytes: 4)
        }
    }

    @Test func doesNotFollowSymlinks() async throws {
        let fx = try LocalFixture()
        let outside = try TestFiles.temporaryDirectory()
        try Data("secret".utf8).write(to: outside.appendingPathComponent("x.json"))
        try FileManager.default.createSymbolicLink(at: fx.root.appendingPathComponent("link.json"),
                                                   withDestinationURL: outside.appendingPathComponent("x.json"))
        await #expect(throws: (any Error).self) { _ = try await fx.destination.readSmallFile(remoteId: "link.json") }
    }
}
