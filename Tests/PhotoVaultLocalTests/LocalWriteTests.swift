import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultLocal

@Suite struct LocalWriteTests {
    @Test func passesConformanceSuite() async throws {
        let fx = try LocalFixture()
        let failures = await DestinationConformanceSuite(destination: fx.destination, root: fx.rootRef, scratch: fx.scratch).run()
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func atomicWriteLeavesNoTempFiles() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        let result = try await fx.upload(try fx.request("x.HEIC", "bytes", in: folder))
        #expect(result.remoteId == "a/x.HEIC")
        #expect(try fx.text("a/x.HEIC") == "bytes")
        #expect(try fx.names(".photovault/tmp").isEmpty)
    }

    @Test func sameHashIsDoneWithoutRewriting() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        let first = try await fx.upload(try fx.request("x.JPG", "same", in: folder))
        let second = try await fx.upload(try fx.request("x.JPG", "same", in: folder))
        #expect(first == second)
        #expect(try fx.names("a") == ["x.JPG"])
    }

    @Test func foreignOriginalGetsConflictNameAndIsUntouched() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        try fx.write("a/x.JPG", "theirs")
        let req = try fx.request("x.JPG", "ours", in: folder)
        let result = try await fx.upload(req)
        #expect(result.finalName == "x (conflict-\(req.content.sha256.prefix(6))).JPG")
        #expect(try fx.text("a/x.JPG") == "theirs")
        #expect(try fx.text("a/" + result.finalName) == "ours")
        let again = try await fx.upload(req)
        #expect(again == result)
    }

    @Test func foreignSidecarIsRefused() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        try fx.write("a/x.json", "theirs")
        let req = try fx.request("x.json", "ours", in: folder, kind: .sidecarJson)
        #expect(await expectError(.foreignFile) { _ = try await fx.upload(req) })
        #expect(try fx.text("a/x.json") == "theirs")
        #expect(try fx.names("a") == ["x.json"])
        #expect(try fx.names(".photovault/tmp").isEmpty)
    }

    @Test func corruptStagedContentIsRejected() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        var req = try fx.request("x.HEIC", "bytes", in: folder)
        req.content.sha256 = String(repeating: "0", count: 64)
        var rejected = false
        do { _ = try await fx.upload(req) } catch DestinationError.checksumMismatch { rejected = true }
        #expect(rejected)
        #expect(try fx.names("a").isEmpty)
        #expect(try fx.names(".photovault/tmp").isEmpty)
    }

    @Test func missingParentFolder() async throws {
        let fx = try LocalFixture()
        let ghost = RemoteFolderRef(logicalPath: "ghost", remoteId: "ghost", displayPath: "ghost")
        #expect(await expectError(.folderMissing(logicalPath: "ghost")) { _ = try await fx.upload(try fx.request("x", "y", in: ghost)) })
    }

    @Test func reservedDirectoryCannotBeUsed() async throws {
        let fx = try LocalFixture()
        #expect(await expectError(.itemRejected(reason: "reserved path")) { _ = try await fx.folder(".photovault") })
    }

    // MARK: Replace

    @Test func replaceOnlyWhenPriorHashMatches() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        let first = try fx.request("e.json", "v1", in: folder, kind: .sidecarJson)
        let created = try await fx.upload(first)

        try fx.write("a/e.json", "edited by owner")
        let blocked = try fx.request("e.json", "v2", in: folder, kind: .sidecarJson, prior: first.content.sha256)
        #expect(await expectError(.foreignModified) { _ = try await fx.destination.replaceContent(remoteId: created.remoteId, blocked) })
        let noPrior = try fx.request("e.json", "v2", in: folder, kind: .sidecarJson)
        #expect(await expectError(.foreignModified) { _ = try await fx.destination.replaceContent(remoteId: created.remoteId, noPrior) })
        #expect(try fx.text("a/e.json") == "edited by owner")

        let ownerHash = TestFiles.hashes(of: Data("edited by owner".utf8)).sha256
        let allowed = try fx.request("e.json", "v2", in: folder, kind: .sidecarJson, prior: ownerHash)
        let replaced = try await fx.destination.replaceContent(remoteId: created.remoteId, allowed)
        #expect(replaced.verifiedHash == allowed.content.sha256)
        #expect(try fx.text("a/e.json") == "v2")
        #expect(try fx.names(".photovault/tmp").isEmpty)
    }

    @Test func replaceMissingFileIsNotFound() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        let req = try fx.request("e.json", "v", in: folder, kind: .sidecarJson, prior: "x")
        #expect(await expectError(.notFound) { _ = try await fx.destination.replaceContent(remoteId: "a/e.json", req) })
    }

    // MARK: Move and rename

    @Test func moveNeverOverwrites() async throws {
        let fx = try LocalFixture()
        let from = try await fx.folder("from"), to = try await fx.folder("to")
        let uploaded = try await fx.upload(try fx.request("m.HEIC", "mine", in: from))
        try fx.write("to/m.HEIC", "theirs")
        #expect(await expectError(.foreignFile) {
            _ = try await fx.destination.move(remoteId: uploaded.remoteId, name: "m.HEIC", from: from, to: to)
        })
        #expect(try fx.text("from/m.HEIC") == "mine")
        #expect(try fx.text("to/m.HEIC") == "theirs")
    }

    @Test func moveIsIdempotentAfterCrash() async throws {
        let fx = try LocalFixture()
        let from = try await fx.folder("from"), to = try await fx.folder("to")
        let uploaded = try await fx.upload(try fx.request("m.HEIC", "mine", in: from))
        let first = try await fx.destination.move(remoteId: uploaded.remoteId, name: "m.HEIC", from: from, to: to)
        let again = try await fx.destination.move(remoteId: uploaded.remoteId, name: "m.HEIC", from: from, to: to)
        #expect(first.remoteId == "to/m.HEIC" && again == first)
    }

    @Test func renameFolderRefusesExistingNameAndIsIdempotent() async throws {
        let fx = try LocalFixture()
        let a = try await fx.folder("a")
        _ = try await fx.folder("b")
        #expect(await expectError(.foreignFile) { _ = try await fx.destination.renameFolder(a, newName: "b") })
        #expect(try fx.names("") .contains("a"))
        let renamed = try await fx.destination.renameFolder(a, newName: "c")
        #expect(renamed.remoteId == "c" && renamed.displayPath == "c")
        let again = try await fx.destination.renameFolder(a, newName: "c")
        #expect(again == renamed)
    }

    @Test func listSkipsReservedDirectoryAndReportsSizes() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        _ = try await fx.upload(try fx.request("x.HEIC", "12345", in: folder))
        var items: [RemoteItem] = []
        for try await item in fx.destination.list(under: nil) { items.append(item) }
        #expect(items.map(\.relativePath) == ["a", "a/x.HEIC"])
        #expect(items.last?.size == 5 && items.last?.sha256 == nil)
        #expect(!items.contains { $0.relativePath?.hasPrefix(".photovault") == true })
    }

    @Test func probeAndQuota() async throws {
        let disk = FakeDiskSpace(available: 100, total: 400)
        let fx = try LocalFixture(disk: disk)
        let folder = try await fx.folder("a")
        let up = try await fx.upload(try fx.request("x.HEIC", "abc", in: folder))
        #expect(try await fx.destination.probe(remoteId: up.remoteId)?.size == 3)
        #expect(try await fx.destination.probe(remoteId: "a/none") == nil)
        #expect(try await fx.destination.probe(remoteId: "nodir/none") == nil)
        let quota = try await fx.destination.quota()
        #expect(quota == Quota(totalBytes: 400, usedBytes: 300, availableBytes: 100))
        #expect(try await fx.destination.reserveIds(count: 2, kind: .files).count == 2)
    }
}

@Suite struct LocalHardeningTests {
    private func ops(_ fx: LocalFixture, memo: ExclusiveRenameMemo = ExclusiveRenameMemo(),
                     afterStaging: (@Sendable () -> Void)? = nil) -> LocalFileOps {
        LocalFileOps(access: PlainURLRoot(fx.root), writer: AtomicFileWriter(), log: NullLogSink(),
                     renameMemo: memo, afterStaging: afterStaging)
    }

    @Test func commonAncestorStopsAtFirstMismatch() {
        #expect(LocalPath.commonAncestor("camera/2024/05/01", "camera/2024/06/01") == "camera/2024")
        #expect(LocalPath.commonAncestor("saved/2023/05", "camera/2023/05") == "")
        #expect(LocalPath.commonAncestor("a/b", "a/b/c") == "a/b")
        #expect(LocalPath.commonAncestor("", "a") == "")
    }

    @Test func replaceRefusesWhenOwnerEditsDuringStaging() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("d")
        let first = try fx.request("meta.json", "v1", in: folder, kind: .sidecarJson)
        _ = try await fx.upload(first)
        let update = try fx.request("meta.json", "v2", in: folder, kind: .sidecarJson, prior: first.content.sha256)
        let target = fx.root.appendingPathComponent("d/meta.json")
        let editing = ops(fx, afterStaging: { try? Data("owner edit".utf8).write(to: target) })
        #expect(throws: DestinationError.foreignModified) { _ = try editing.replace(path: "d/meta.json", update) }
        #expect(try fx.text("d/meta.json") == "owner edit")
        #expect(try fx.names(".photovault/tmp").isEmpty)
        // Untouched file is replaced.
        let clean = try fx.request("meta.json", "v2", in: folder, kind: .sidecarJson, prior: first.content.sha256)
        try fx.write("d/meta.json", "v1")
        _ = try ops(fx).replace(path: "d/meta.json", clean)
        #expect(try fx.text("d/meta.json") == "v2")
    }

    @Test func knownUnsupportedVolumeSkipsStagingOnFirstPass() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("d")
        let memo = ExclusiveRenameMemo()
        let request = try fx.request("a.bin", "data", in: folder)
        // Supported volume: the unlocked pass succeeds.
        _ = try ops(fx, memo: memo).upload(request, allowFallback: false)
        let dev = try FileManager.default.attributesOfItem(atPath: fx.root.path)[.systemNumber] as! NSNumber
        memo.markUnsupported(dev_t(dev.int32Value))
        let second = try fx.request("b.bin", "data2", in: folder)
        #expect(throws: ExclusiveRenameUnsupported.self) { _ = try ops(fx, memo: memo).upload(second, allowFallback: false) }
        #expect(try fx.names(".photovault/tmp").isEmpty)
        // The locked pass still places the file with the check-then-rename fallback.
        _ = try ops(fx, memo: memo).upload(second, allowFallback: true)
        #expect(try fx.text("d/b.bin") == "data2")
        #expect(try fx.names(".photovault/tmp").isEmpty)
    }

    @Test func permissionErrorBelowTheRootIsItemLevel() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("locked")
        let request = try fx.request("a.bin", "data", in: folder)
        let path = fx.root.appendingPathComponent("locked").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        do {
            _ = try await fx.upload(request)
            Issue.record("expected a permission error")
        } catch let error as DestinationError {
            #expect(error == .itemRejected(reason: "permission"))
        }
        #expect(await fx.destination.checkAvailability() == .active)
    }

    @Test func sweepSparesPartsOfAnotherDestinationObject() async throws {
        let fx = try LocalFixture()
        let tmp = try DirectoryHandle.openRoot(fx.root).openDirectory(".photovault/tmp", create: true)
        let payload = Data("in flight".utf8)
        let part = try AtomicFileWriter().stage(.data(payload), expectedSHA256: FileHashing.sha256(payload), in: tmp)
        let replacement = LocalFolderDestination(id: .local(), root: PlainURLRoot(fx.root))
        #expect(await replacement.checkAvailability() == .active)
        #expect(try fx.names(".photovault/tmp") == [part])
        // An orphan nobody is writing is still removed.
        let orphan = UUID().uuidString + ".part"
        try fx.write(".photovault/tmp/" + orphan, "orphan")
        #expect(await replacement.checkAvailability() == .active)
        #expect(try fx.names(".photovault/tmp") == [part])
    }
}
