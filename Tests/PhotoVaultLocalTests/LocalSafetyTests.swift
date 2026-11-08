import Darwin
import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultLocal

@Suite struct LocalSafetyTests {
    private func symlink(_ target: URL, at link: URL) throws {
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    private func outsideDirectory(_ fx: LocalFixture) throws -> URL {
        let outside = fx.scratch.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return outside
    }

    @Test func symlinkedFinalFileIsRefused() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        let outside = fx.scratch.appendingPathComponent("victim.txt")
        try Data("victim".utf8).write(to: outside)
        try symlink(outside, at: fx.root.appendingPathComponent("a/x.JPG"))
        let req = try fx.request("x.JPG", "ours", in: folder)
        #expect(await expectError(.itemRejected(reason: "symlink")) { _ = try await fx.upload(req) })
        #expect(try String(contentsOf: outside, encoding: .utf8) == "victim")
        #expect(try fx.names(".photovault/tmp").isEmpty)
    }

    @Test func symlinkedIntermediateFolderIsRefused() async throws {
        let fx = try LocalFixture()
        let outside = try outsideDirectory(fx)
        try symlink(outside, at: fx.root.appendingPathComponent("link"))
        let linked = RemoteFolderRef(logicalPath: "link", remoteId: "link", displayPath: "link")
        let req = try fx.request("x.JPG", "ours", in: linked)
        #expect(await expectError(.itemRejected(reason: "symlink")) { _ = try await fx.upload(req) })
        #expect(await expectError(.itemRejected(reason: "symlink")) { _ = try await fx.folder("sub", in: linked) })
        #expect(await expectError(.itemRejected(reason: "symlink")) { _ = try await fx.destination.probe(remoteId: "link/x.JPG") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func symlinkedFolderAtEnsureFolderIsRefused() async throws {
        let fx = try LocalFixture()
        let outside = try outsideDirectory(fx)
        try symlink(outside, at: fx.root.appendingPathComponent("a"))
        #expect(await expectError(.itemRejected(reason: "symlink")) { _ = try await fx.folder("a") })
    }

    @Test func symlinkedTmpDirectoryIsRefused() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        let outside = try outsideDirectory(fx)
        try FileManager.default.createDirectory(at: fx.root.appendingPathComponent(".photovault"), withIntermediateDirectories: true)
        try symlink(outside, at: fx.tmpURL)
        let req = try fx.request("x.JPG", "ours", in: folder)
        #expect(await expectError(.itemRejected(reason: "symlink")) { _ = try await fx.upload(req) })
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(await fx.destination.checkAvailability() == .paused(.rootMissing))
    }

    @Test func listNeverFollowsSymlinks() async throws {
        let fx = try LocalFixture()
        let outside = try outsideDirectory(fx)
        try Data("x".utf8).write(to: outside.appendingPathComponent("leak.txt"))
        try symlink(outside, at: fx.root.appendingPathComponent("link"))
        try symlink(outside.appendingPathComponent("leak.txt"), at: fx.root.appendingPathComponent("file-link"))
        var items: [RemoteItem] = []
        for try await item in fx.destination.list(under: nil) { items.append(item) }
        #expect(items.isEmpty)
    }

    @Test func orphanSweepRemovesOnlyMatchingPartFiles() async throws {
        let fx = try LocalFixture()
        let tmp = fx.tmpURL
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let orphan = UUID().uuidString + ".part"
        for name in [orphan, UUID().uuidString + ".part", "keep.part", UUID().uuidString.lowercased() + ".part",
                     UUID().uuidString + ".txt", "notes.txt"] {
            try Data("x".utf8).write(to: tmp.appendingPathComponent(name))
        }
        let status = await fx.destination.checkAvailability()
        #expect(status == .active)
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        #expect(left.count == 4)
        #expect(!left.contains(orphan))
        #expect(left.contains("keep.part") && left.contains("notes.txt"))
    }

    @Test func onlyOwnedNamesCanBeUnlinked() throws {
        let fx = try LocalFixture()
        let dir = try DirectoryHandle.openRoot(fx.root)
        try fx.write("photo.HEIC", "precious")
        try fx.write("keep.part", "precious")
        for name in ["photo.HEIC", "keep.part", "destination.json"] {
            #expect(throws: DestinationError.itemRejected(reason: "not deletable")) { try dir.unlinkOwned(name) }
        }
        #expect(try fx.names("").sorted() == ["keep.part", "photo.HEIC"])
        #expect(DirectoryHandle.isOwnedPartName(UUID().uuidString + ".part"))
        #expect(!DirectoryHandle.isOwnedPartName("../" + UUID().uuidString + ".part"))
    }

    @Test func testConnectionLeavesNothingBehind() async throws {
        let fx = try LocalFixture()
        try fx.write(".photovault-test", "stale")
        try await fx.destination.testConnection()
        #expect(try fx.names("").isEmpty)
    }

    @Test func offlineRootIsUnavailable() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("pv-nonexistent-\(UUID().uuidString)")
        let destination = LocalFolderDestination(id: .local(), root: PlainURLRoot(missing))
        #expect(await destination.checkAvailability() == .unavailable(.offline))
        #expect(await expectError(.offline) { try await destination.testConnection() })
    }

    @Test func invalidBookmarkIsUnavailable() async throws {
        let root = SecurityScopedBookmarkRoot(bookmark: Data("not a bookmark".utf8), onRefresh: { _ in })
        let destination = LocalFolderDestination(id: .local(), root: root)
        #expect(await destination.checkAvailability() == .unavailable(.bookmarkInvalid))
    }

    @Test func bookmarkRoundTrip() async throws {
        let fx = try LocalFixture()
        let bookmark = try SecurityScopedBookmarkRoot.makeBookmark(for: fx.root)
        let destination = LocalFolderDestination(id: .local(), root: SecurityScopedBookmarkRoot(bookmark: bookmark, onRefresh: { _ in }))
        #expect(await destination.checkAvailability() == .active)
        try await destination.testConnection()
    }
}
