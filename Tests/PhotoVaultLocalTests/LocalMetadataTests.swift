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

    @Test func renameRecoveryDecisions() async throws {
        #expect(FolderRenameRecovery.decide(oldExists: false, newExists: true) == .commit)
        #expect(FolderRenameRecovery.decide(oldExists: true, newExists: false) == .retry)
        #expect(FolderRenameRecovery.decide(oldExists: true, newExists: true) == .retry)
        #expect(FolderRenameRecovery.decide(oldExists: false, newExists: false) == .integrityCheck)

        let fx = try LocalFixture()
        let a = try await fx.folder("old")
        #expect(try await fx.destination.recoverRename(oldPath: "old", newPath: "new") == .retry)
        _ = try await fx.destination.renameFolder(a, newName: "new")
        #expect(try await fx.destination.recoverRename(oldPath: "old", newPath: "new") == .commit)
        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("new"))
        #expect(try await fx.destination.recoverRename(oldPath: "old", newPath: "new") == .integrityCheck)
    }

    // MARK: Integrity

    private func expected(_ count: Int, size: Int64 = 10) -> [ExpectedFile] {
        (0..<count).map { ExpectedFile(path: "d/f\($0).bin", size: size, sha256: "h\($0)") }
    }

    @Test func sampleIsOnePercentDeterministicAndRotates() {
        let files = expected(1000)
        let sample = IntegrityWalker.sample(files, seed: "2026-11-09")
        #expect(sample.count == 10)
        #expect(sample == IntegrityWalker.sample(files.reversed(), seed: "2026-11-09"))
        #expect(Set(sample.map(\.path)) != Set(IntegrityWalker.sample(files, seed: "2026-11-10").map(\.path)))
        #expect(IntegrityWalker.sample(expected(5), seed: "s").count == 1)
        #expect(IntegrityWalker.sample([], seed: "s").isEmpty)
        #expect(IntegrityWalker.sample([ExpectedFile(path: "x", size: 1, sha256: nil)], seed: "s").isEmpty)
    }

    @Test func sampleRespectsByteCap() {
        let gib: Int64 = 1 << 30
        let files = (0..<200).map { ExpectedFile(path: "big\($0)", size: 2 * gib, sha256: "h") }
        let sample = IntegrityWalker.sample(files, seed: "s", fraction: 1.0)
        #expect(sample.count == 2)
        #expect(sample.reduce(0) { $0 + $1.size } <= IntegrityWalker.sampleByteCap)
    }

    @Test func integrityFindsMissingSizeAndBitRot() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("d")
        let good = try fx.request("good.bin", "good", in: folder)
        let rot = try fx.request("rot.bin", "rot!", in: folder)
        let short = try fx.request("short.bin", "short", in: folder)
        for r in [good, rot, short] { _ = try await fx.upload(r) }
        try fx.write("d/rot.bin", "rotX")          // same size, different bytes
        try fx.write("d/short.bin", "sho")          // different size
        let files = [good, rot, short].map { ExpectedFile(path: "d/" + $0.fileName, size: $0.content.size, sha256: $0.content.sha256) }
            + [ExpectedFile(path: "d/gone.bin", size: 1, sha256: "x"), ExpectedFile(path: "nodir/x.bin", size: 1, sha256: "x")]
        // Fraction 1.0 equivalent: 4 eligible files * 1 % rounds up to 1, so run the walker per file seed until rot is sampled.
        var found = false
        for seed in 0..<50 {
            let report = try await fx.destination.verifyIntegrity(expected: files, seed: "s\(seed)")
            #expect(report.missing.sorted() == ["d/gone.bin", "nodir/x.bin"])
            #expect(report.sizeMismatch == ["d/short.bin"])
            #expect(report.hashedCount <= 1)
            if report.hashMismatch == ["d/rot.bin"] { found = true }
            #expect(report.hashMismatch.isEmpty || report.hashMismatch == ["d/rot.bin"])
        }
        #expect(found)
        let clean = try await fx.destination.verifyIntegrity(expected: [ExpectedFile(path: "d/good.bin", size: 4, sha256: good.content.sha256)], seed: "s")
        #expect(clean.isClean && clean.hashedCount == 1)
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
