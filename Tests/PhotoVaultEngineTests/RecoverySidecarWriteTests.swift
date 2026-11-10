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

    private func driveFileMd5s(_ h: Harness) async -> [String: String] {
        await Dictionary(uniqueKeysWithValues: h.drive.files.map { ($0.name, $0.content?.md5 ?? "") })
    }

    @Test func aDriveSidecarChangedWhileTheDatabaseWasLostIsWrittenOnce() async throws {
        let h = try await driveLife()
        let before = await driveSidecarWrites(h)
        let md5s = await driveFileMd5s(h)
        try await h.loseDatabase()
        var favorite = h.snapshot("d0", daysAgo: 3, location: daLat)
        favorite.isFavorite = true
        await h.fakePhotos.update(favorite)
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)
        #expect(await driveSidecarWrites(h) == before + 2, "json and xmp of the changed asset, once")
        let changed = await h.drive.files.filter { md5s[$0.name] != $0.content?.md5 }.map(\.name).sorted()
        #expect(changed.count == 2 && changed.allSatisfy { $0.contains("IMG_d0.") && ($0.hasSuffix(".json") || $0.hasSuffix(".xmp")) }, "\(changed)")
        await h.settle(rounds: 4)
        #expect(await driveSidecarWrites(h) == before + 2)
    }

    @Test func aDriveSidecarThatCannotBeReadIsWrittenOnce() async throws {
        let h = try await driveLife()
        let before = await driveSidecarWrites(h)
        let victim = try #require(await h.drive.files.first { $0.name.hasSuffix("IMG_d1.json") })
        var damaged = victim
        damaged.data = Data("not a sidecar".utf8)
        await h.drive.put(damaged)
        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)
        let writes = await driveSidecarWrites(h) - before
        #expect(writes >= 1 && writes <= 2, "only the unreadable sidecar (and its xmp) is written, once: \(writes)")
        await h.settle(rounds: 4)
        #expect(await driveSidecarWrites(h) - before == writes)
        #expect(try sidecarJobGenerations(h).filter { $0 > 1 }.count == writes)
    }

    @Test func recoveryFillsCameraFieldsAndHashesOnlyWhereTheyAreEmpty() async throws {
        let h = try await driveLife()
        try h.write { db in
            try db.execute(sql: "UPDATE asset SET lens_model = NULL, camera_model = NULL WHERE asset_key = 'l:d1'")
            try db.execute(sql: "UPDATE resource SET md5 = NULL, sha256 = NULL WHERE asset_key = 'l:d1'")
        }
        let record = try h.destinationRecord(.googleDrive)
        let writer = RecoveryWriter(env: h.env, record: record, timeZone: .gmt)
        var files: [RecoveredFile] = []
        for key in ["l:d0", "l:d1"] {
            let assetKey = try #require(AssetKey(rawValue: key))
            let job = try #require(try h.jobs().first { $0.assetKey == assetKey && !$0.resType.isSidecar })
            var entry = RemoteFileEntry(
                item: RemoteItem(remoteId: job.remoteId ?? "", name: job.remoteName ?? "", parentIds: [], kind: .file),
                parentLogical: job.remoteLogicalParent)
            entry.contentMd5 = "md5-from-sidecar"
            entry.contentSha256 = "sha-from-sidecar"
            entry.camera = SidecarDocument.Camera(make: "Other", model: "Other model", lens: "Other lens")
            files.append(RecoveredFile(entry: entry, assetKey: assetKey, resType: job.resType, alias: nil))
        }
        _ = try await writer.writeFiles(files)
        let rows = try h.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.asset_key, a.camera_model, a.lens_model, r.md5 FROM asset a JOIN resource r ON r.asset_key = a.asset_key
                WHERE a.asset_key IN ('l:d0', 'l:d1') ORDER BY a.asset_key
                """)
        }
        #expect(rows[0]["lens_model"] as String? == "Wide" && rows[0]["camera_model"] as String? == "iPhone 15", "values already there stay")
        #expect(rows[0]["md5"] as String? != "md5-from-sidecar")
        #expect(rows[1]["lens_model"] as String? == "Other lens" && rows[1]["camera_model"] as String? == "Other model")
        #expect(rows[1]["md5"] as String? == "md5-from-sidecar")
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
