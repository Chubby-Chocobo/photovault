import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// After a database loss the sidecars already at the destination are recorded as up to date; only a
/// sidecar whose content really differs from what the app writes now is written again.
@Suite struct RecoverySidecarWriteTests {
    private func driveLife() async throws -> Harness {
        let h = try await Harness.organized()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        try h.addDrive(scope: .full)
        await h.addCameraAssets(5, prefix: "d", daysAgo: 3, recordChange: false, location: daLat)
        await h.add(h.snapshot("other", daysAgo: 40), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)
        return h
    }

    private func localLife() async throws -> (Harness, URL, DirectoryReader) {
        let h = try await Harness.organized()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        let (_, root, reader) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        await h.addCameraAssets(5, prefix: "d", daysAgo: 3, recordChange: false, location: daLat)
        try await h.baseline(h.nasId)
        await h.settle(rounds: 8)
        return (h, root, reader)
    }

    private func driveSidecarWrites(_ h: Harness) async -> Int {
        await h.drive.operationLog.filter { $0 == .upload || $0 == .replace }.count
    }

    private func sidecarFiles(_ root: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for path in treeListing(root).keys where path.hasSuffix(".json") && !path.hasPrefix(".photovault") || path.hasSuffix(".xmp") {
            result[path] = try? Data(contentsOf: root.appendingPathComponent(path))
        }
        return result
    }

    private func sidecarModificationDates(_ root: URL) -> [String: Date] {
        var result: [String: Date] = [:]
        for path in sidecarFiles(root).keys {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            result[path] = attributes?[.modificationDate] as? Date
        }
        return result
    }

    private func sidecarJobGenerations(_ h: Harness) throws -> [Int] {
        try h.read { db in try Int.fetchAll(db, sql: "SELECT target_gen FROM upload_job WHERE res_type IN (1001, 1002)") }
    }

    @Test func driveRecoveryWritesNoSidecarAgain() async throws {
        let h = try await driveLife()
        let before = await driveSidecarWrites(h)
        #expect(try sidecarJobGenerations(h).count >= 12)
        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)
        #expect(await driveSidecarWrites(h) == before, "recovery must not upload or replace any sidecar")
        #expect(try sidecarJobGenerations(h).allSatisfy { $0 == 1 })
    }

    @Test func aDriveSidecarIsWrittenOnceWhenAnInputChangesAfterRecovery() async throws {
        let h = try await driveLife()
        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)
        let recovered = await driveSidecarWrites(h)

        var favorite = h.snapshot("d0", daysAgo: 3)
        favorite.isFavorite = true
        favorite.location = daLat
        await h.fakePhotos.update(favorite)
        await h.settle(rounds: 8)
        #expect(await driveSidecarWrites(h) == recovered + 2, "json and xmp of the changed asset are replaced once")
        await h.settle(rounds: 4)
        #expect(await driveSidecarWrites(h) == recovered + 2)
    }

    @Test func localRecoveryWritesNoSidecarAgain() async throws {
        let (h, root, reader) = try await localLife()
        let contents = sidecarFiles(root)
        let dates = sidecarModificationDates(root)
        #expect(contents.count == 10)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await h.loseDatabase(localContent: reader)
        try h.addNAS(scope: .full)
        try await h.baseline(h.nasId)
        await h.settle(rounds: 8)
        #expect(sidecarModificationDates(root) == dates, "recovery must not rewrite any sidecar")
        #expect(sidecarFiles(root) == contents)
        #expect(try sidecarJobGenerations(h).allSatisfy { $0 == 1 })
    }

    @Test func aLocalSidecarThatReallyDiffersIsWrittenOnce() async throws {
        let (h, root, reader) = try await localLife()
        let contents = sidecarFiles(root)
        let dates = sidecarModificationDates(root)
        let victim = try #require(contents.keys.first { $0.hasSuffix("IMG_d0.json") })
        let data = try #require(contents[victim])
        let original = try #require(String(data: data, encoding: .utf8))
        let edited = original.replacingOccurrences(of: "\"albums\": []", with: "\"albums\": [\"Old album\"]")
        #expect(edited != original)
        try Data(edited.utf8).write(to: root.appendingPathComponent(victim))
        try await Task.sleep(nanoseconds: 50_000_000)

        try await h.loseDatabase(localContent: reader)
        try h.addNAS(scope: .full)
        try await h.baseline(h.nasId)
        await h.settle(rounds: 8)

        let after = sidecarModificationDates(root)
        #expect(after.filter { dates[$0.key] != $0.value }.keys.sorted() == [victim], "only the differing sidecar is written")
        #expect(sidecarFiles(root) == contents, "and it is back to what the app writes now")
        #expect(try sidecarJobGenerations(h).sorted() == Array(repeating: 1, count: 9) + [2])
    }
}
