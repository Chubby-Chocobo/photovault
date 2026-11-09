import Foundation
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Recovery and crash safety with the real `LocalFolderDestination` in a temporary folder (spec 8.15
/// local, FR-74, FR-76).
@Suite struct LocalRecoveryTests {
    private func organizedLocalLife() async throws -> (Harness, URL, DirectoryReader) {
        let h = try await Harness.organized()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        let (_, root, reader) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        await h.addCameraAssets(5, prefix: "d", daysAgo: 3, recordChange: false, location: daLat)
        await h.add(h.snapshot("other", daysAgo: 40), recordChange: false)
        try await h.baseline(h.nasId)
        await h.settle(rounds: 8)
        return (h, root, reader)
    }

    private func mediaFiles(_ root: URL) -> [String: Int] {
        treeListing(root).filter { !$0.key.hasPrefix(".photovault") && !$0.key.hasSuffix(".json") && !$0.key.hasSuffix(".xmp") }
    }

    @Test func t31LostDatabaseIsRecoveredFromTheFolderTree() async throws {
        let (h, root, reader) = try await organizedLocalLife()
        let media = mediaFiles(root)
        #expect(media.count == 6, "\(media.keys.sorted())")
        let paths = Set(treeListing(root).keys)
        let folders = folderListing(root)
        #expect(folders.contains { $0.contains("2026-10-23 Đà Lạt") }, "the day folder carries the place name: \(folders)")
        let placements = try h.placements()
        let allocations = try h.nameAllocations()
        let doneBefore = try h.jobs(.done).count

        try await h.loseDatabase(localContent: reader)
        try h.addNAS(scope: .full)
        try await h.baseline(h.nasId)
        await h.settle(rounds: 8)

        #expect(Set(treeListing(root).keys) == paths, "no file added, none renamed or conflict-copied")
        #expect(folderListing(root) == folders, "no folder was split")
        for (path, size) in media { #expect(treeListing(root)[path] == size, "the original \(path) was not rewritten") }
        #expect(try h.placements() == placements)
        #expect(try h.nameAllocations() == allocations)
        #expect(try h.jobs(.done).count == doneBefore)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        let stat = try #require(try h.dayStat(organizationDay))
        #expect(stat.promoted && stat.placeName == "Đà Lạt")
        let hashes = try h.read { db in try JobRepository.fetch(db, state: .done).compactMap(\.uploadedHash) }
        #expect(hashes.count == doneBefore, "every recovered file has the hash the sidecar recorded or the verification computed")
        #expect(!treeListing(root).keys.contains { $0.hasSuffix(".part") })
    }

    @Test func aReAddedFolderWithItsMarkerIsRecoveredWhenTheOwnerReusesIt() async throws {
        let (h, root, reader) = try await organizedLocalLife()
        let paths = Set(treeListing(root).keys)
        try await h.loseDatabase(localContent: reader)
        try h.addNAS(scope: .full)
        try await h.coordinator.adoptExistingRoot(h.nasId, rootId: "")
        let record = try h.destinationRecord(h.nasId)
        #expect(record.recoveryRequired && record.status == .paused(.recovering))
        try await h.baseline(h.nasId)
        await h.settle(rounds: 8)
        #expect(Set(treeListing(root).keys) == paths)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
    }

    @Test func aRecoveredFileWhoseSizeDiffersFromItsSidecarIsMissingAndTheOwnerIsToldNothingIsOverwritten() async throws {
        let h = try await Harness.organized()
        let (_, root, reader) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        for index in 0..<3 { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(h.nasId)
        await h.settle()
        let victim = try #require(mediaFiles(root).keys.sorted().first)
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(victim))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tail".utf8))
        try handle.close()
        let before = mediaFiles(root)
        let sidecars = treeListing(root).keys.filter { $0.hasSuffix(".json") || $0.hasSuffix(".xmp") }.sorted()

        try await h.loseDatabase(localContent: reader)
        try h.addNAS(scope: .full)
        try await h.baseline(h.nasId)
        await h.settle()

        #expect(mediaFiles(root) == before, "the damaged file is neither replaced nor copied")
        #expect(treeListing(root).keys.filter { $0.hasSuffix(".json") || $0.hasSuffix(".xmp") }.sorted() == sidecars)
        let missing = try h.jobs(.missingRemote)
        #expect(missing.count == 1 && missing[0].remoteName == (victim as NSString).lastPathComponent)
        #expect(try h.activity().contains { $0.kind == .missingFile })
        #expect(await h.coordinator.pendingOwnerDecisions().contains(.integrityMissing(h.nasId, count: 1)))
        #expect(try h.jobs(.done).count == 8, "three originals and six sidecars, one original in doubt")
    }

    // MARK: FR-76

    @Test func localIntegrityFindsMissingTruncatedAndRottedFilesThroughTheDestinationApi() async throws {
        let h = try await Harness()
        let (_, root, _) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        for index in 0..<4 { await h.add(h.snapshot("q\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(h.nasId)
        await h.settle()
        let files = mediaFiles(root).keys.sorted()
        #expect(files.count == 4)
        try FileManager.default.removeItem(at: root.appendingPathComponent(files[0]))
        try Data("x".utf8).write(to: root.appendingPathComponent(files[1]))
        // Same size, different bytes: only the re-hash can see it.
        for name in files[2...] {
            var data = try Data(contentsOf: root.appendingPathComponent(name))
            data[0] ^= 0xFF
            try data.write(to: root.appendingPathComponent(name))
        }

        let report = try await h.coordinator.runIntegrityCheck(h.nasId)
        #expect(report.checked == 4 && report.missing == 1 && report.sizeMismatch == 1)
        #expect(report.hashMismatch == 1 && report.hashed == 1, "the 1 % sample (at least one file) was read again")
        #expect(try h.jobs(.missingRemote).count == 3)
        let before = treeListing(root)
        await h.settle()
        #expect(treeListing(root) == before, "nothing is uploaded again before the owner confirms")
    }

    // MARK: Crash safety

    @Test(arguments: CrashPoint.allCases.filter { ![.afterFolderIdPersisted, .afterFileIdReserved, .afterFileIdPersisted, .afterSessionPersisted, .afterImportInspectBeforeCommit, .afterImportGroupCommit].contains($0) })
    func crashingAtEveryStepLeavesNoPartFileNoDuplicateAndNoSplitFolder(_ point: CrashPoint) async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        let (_, root, _) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        for index in 0..<3 { await h.add(h.snapshot("c\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(h.nasId)
        h.injector.arm(point)
        await h.run()
        #expect(h.injector.visited.contains(point))
        // A write killed half way leaves its temp file behind; the next availability check sweeps it.
        let tmp = root.appendingPathComponent(".photovault/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: tmp.appendingPathComponent(UUID().uuidString + ".part"))

        try await h.restart()
        try await h.coordinator.start()
        for _ in 0..<4 {
            await h.run()
            h.clock.advance(by: 3 * 3600)
        }
        let tree = treeListing(root)
        let media = tree.keys.filter { !$0.hasPrefix(".photovault") }
        #expect(media.count == 3, "\(media.sorted())")
        #expect(media.allSatisfy { !$0.contains("conflict") }, "no conflict copy")
        #expect(!tree.keys.contains { $0.hasSuffix(".part") }, "no temp file is left")
        let folders = folderListing(root)
        #expect(folders.count == 4 && folders.contains("Camera Uploads"), "Camera Uploads once and one folder per day: \(folders)")
        #expect(folders.filter { $0 != "Camera Uploads" }.allSatisfy { $0.hasPrefix("Camera Uploads/20") })
        #expect(try h.jobs().allSatisfy { $0.state == .done } && (try h.jobs().count) == 3)
        #expect(h.stagingFiles().isEmpty)
    }
}

/// Strategy 2 of spec 8.15: the identifiers written in the sidecar.
@Suite struct SidecarIdentityRecoveryTests {
    @Test func aSidecarsCloudIdentifierTiesTheFileToTheAssetWhenItsKeyIsGone() async throws {
        let h = try await Harness.organized()
        let (_, root, reader) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("A", daysAgo: 2), recordChange: false)
        try await h.baseline(h.nasId)
        await h.settle()
        let media = treeListing(root).keys.filter { !$0.hasPrefix(".photovault") }.sorted()
        #expect(media.count == 3, "photo, json and xmp: \(media)")

        // Photos tells the cloud identifier later; FR-53 records it and the sidecar is refreshed with it.
        await h.fakePhotos.add(h.snapshot("A", daysAgo: 2, cloud: "CLOUD-A"), recordChange: false)
        h.clock.advance(by: 2 * 3600)
        await h.settle()
        let sidecar = try #require(media.first { $0.hasSuffix(".json") })
        let text = try String(contentsOf: root.appendingPathComponent(sidecar), encoding: .utf8)
        #expect(text.contains("\"cloudIdentifier\": \"CLOUD-A\"") && text.contains("\"assetKey\": \"l:A\""))
        let before = treeListing(root).keys.sorted()

        // The library is rebuilt and the database lost: the local identifier is new, the key `l:A` is nowhere.
        await h.fakePhotos.rebuildLibrary(renaming: ["A": "A-rebuilt"])
        try await h.loseDatabase(localContent: reader)
        try h.addNAS(scope: .full)
        try await h.baseline(h.nasId)
        await h.settle()

        #expect(treeListing(root).keys.sorted() == before, "nothing was added")
        let asset = try #require(try h.asset(.cloud("CLOUD-A")))
        #expect(try h.aliases(of: asset.assetKey).contains("A"), "the old key's identifier is an alias")
        #expect(try h.jobs(.done).count == 3)
    }
}
