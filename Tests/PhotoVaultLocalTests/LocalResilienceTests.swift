import Darwin
import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultLocal

@Suite struct LocalResilienceTests {
    private func collect(_ stream: AsyncThrowingStream<RemoteItem, any Error>) async throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        for try await item in stream { items.append(item) }
        return items
    }

    private func identity(_ url: URL) throws -> String {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw POSIXError(.ENOENT) }
        return "\(st.st_dev):\(st.st_ino)"
    }

    // MARK: Directory reads

    @Test func readdirFailureIsNotAShortListing() throws {
        let fx = try LocalFixture()
        for name in ["a", "b", "c"] { try fx.write(name, name) }
        let handle = try DirectoryHandle.openRoot(fx.root)
        var calls = 0
        #expect(throws: DestinationError.offline) {
            _ = try handle.entries { dir in
                calls += 1
                if calls == 2 {
                    errno = EIO
                    return nil
                }
                return readdir(dir)
            }
        }
        #expect(try handle.entries().sorted() == ["a", "b", "c"])
    }

    @Test func staleErrnoDoesNotFailACompleteListing() throws {
        let fx = try LocalFixture()
        try fx.write("a", "a")
        let handle = try DirectoryHandle.openRoot(fx.root)
        errno = ETIMEDOUT
        #expect(try handle.entries().sorted() == ["a"])
    }

    @Test func ownerNamesLongerThanOurLimitAreListedAndProbed() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        let long = String(repeating: "\u{5199}", count: 100) + ".JPG"  // 304 UTF-8 bytes
        #expect(long.utf8.count > 255)
        try fx.write("a/" + long, "owner")
        try fx.write("a/short.JPG", "owner")
        let items = try await collect(fx.destination.list(under: nil))
        #expect(items.map(\.remoteId).contains("a/short.JPG"))
        #expect(items.map(\.remoteId).contains("a/" + long))
        #expect(try await fx.destination.probe(remoteId: "a/" + long)?.kind == .file)
        // Names the app creates stay capped.
        let request = try fx.request(long, "ours", in: folder)
        #expect(await expectError(.itemRejected(reason: "invalid name")) { _ = try await fx.upload(request) })
    }

    @Test func entryThatCannotBeDescribedIsSkippedNotFatal() async throws {
        let fx = try LocalFixture()
        let outside = fx.scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fx.root.appendingPathComponent("link"), withDestinationURL: outside)
        try fx.write("kept.JPG", "owner")
        let items = try await collect(fx.destination.list(under: nil))
        #expect(items.map(\.remoteId) == ["kept.JPG"])
    }

    // MARK: Sweep

    @Test func orphanThatCannotBeRemovedDoesNotPauseTheDestination() async throws {
        let fx = try LocalFixture()
        try FileManager.default.createDirectory(at: fx.tmpURL, withIntermediateDirectories: true)
        let stuck = fx.tmpURL.appendingPathComponent("\(UUID().uuidString).part")
        let removable = fx.tmpURL.appendingPathComponent("\(UUID().uuidString).part")
        try Data("x".utf8).write(to: stuck)
        try Data("y".utf8).write(to: removable)
        #expect(chflags(stuck.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(stuck.path, 0) }
        #expect(await fx.destination.checkAvailability() == .active)
        #expect(!FileManager.default.fileExists(atPath: removable.path))
    }

    // MARK: Durability

    private func syncRecorder(_ fx: LocalFixture) -> (LocalFolderDestination, Locked<[String]>) {
        let synced = Locked<[String]>([])
        let destination = LocalFolderDestination(id: .local(), root: PlainURLRoot(fx.root), renameMemo: .volumes,
                                                 onDirectorySync: { id in synced.set(synced.value + [id]) })
        return (destination, synced)
    }

    @Test func folderCreationFlushesTheParent() async throws {
        let fx = try LocalFixture()
        let (destination, synced) = syncRecorder(fx)
        let a = try await destination.ensureFolder(FolderRequest(logicalPath: "a", name: "a", parent: fx.rootRef, reservedId: nil, appProperties: [:]))
        #expect(synced.value.contains(try identity(fx.root)))
        synced.set([])
        _ = try await destination.ensureFolder(FolderRequest(logicalPath: "a/b", name: "b", parent: a, reservedId: nil, appProperties: [:]))
        #expect(synced.value.contains(try identity(fx.root.appendingPathComponent("a"))))
    }

    @Test func folderRenameFlushesTheParent() async throws {
        let fx = try LocalFixture()
        let (destination, synced) = syncRecorder(fx)
        let a = try await destination.ensureFolder(FolderRequest(logicalPath: "a", name: "a", parent: fx.rootRef, reservedId: nil, appProperties: [:]))
        synced.set([])
        _ = try await destination.renameFolder(a, newName: "b")
        #expect(synced.value.contains(try identity(fx.root)))
    }

    @Test func moveFlushesBothFolders() async throws {
        let fx = try LocalFixture()
        let from = try await fx.folder("from")
        let to = try await fx.folder("to")
        try fx.write("from/x.JPG", "owner-visible")
        let (destination, synced) = syncRecorder(fx)
        _ = try await destination.move(remoteId: "from/x.JPG", name: "x.JPG", from: from, to: to)
        #expect(synced.value.contains(try identity(fx.root.appendingPathComponent("from"))))
        #expect(synced.value.contains(try identity(fx.root.appendingPathComponent("to"))))
    }

    // MARK: Blocking work stays off the Swift pool

    private struct QueueLabelRoot: RootAccess {
        let url: URL
        let labels: Locked<[String]>
        func withRoot<T>(_ body: (URL) throws -> T) throws -> T {
            labels.set(labels.value + [String(cString: __dispatch_queue_get_label(nil))])
            return try body(url)
        }
    }

    @Test func listAndQuotaRunOnTheMetadataQueue() async throws {
        let fx = try LocalFixture()
        try fx.write("a.JPG", "owner")
        let labels = Locked<[String]>([])
        let destination = LocalFolderDestination(id: .local(), root: QueueLabelRoot(url: fx.root, labels: labels))
        _ = try await collect(destination.list(under: nil))
        _ = try await destination.quota()
        #expect(labels.value.count == 2)
        #expect(labels.value.allSatisfy { $0.hasPrefix("photovault.local.meta.") })
    }

    // MARK: Root moved while cached

    @Test func renamedRootIsFollowedInsteadOfReportedMissing() async throws {
        let base = try TestFiles.temporaryDirectory("pv-rename").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let access = SecurityScopedBookmarkRoot(bookmark: try SecurityScopedBookmarkRoot.makeBookmark(for: root),
                                                cacheWindow: 600, onRefresh: { _ in })
        let destination = LocalFolderDestination(id: .local(), root: access)
        #expect(await destination.checkAvailability() == .active)
        try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("backup-renamed", isDirectory: true))
        #expect(await destination.checkAvailability() == .active)
        #expect(access.resolveCount == 2)
    }

    @Test func genuinelyDeletedRootIsStillMissing() async throws {
        let base = try TestFiles.temporaryDirectory("pv-gone").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let access = SecurityScopedBookmarkRoot(bookmark: try SecurityScopedBookmarkRoot.makeBookmark(for: root),
                                                cacheWindow: 600, onRefresh: { _ in })
        let destination = LocalFolderDestination(id: .local(), root: access)
        #expect(await destination.checkAvailability() == .active)
        try FileManager.default.removeItem(at: root)
        #expect(await destination.checkAvailability() == .paused(.rootMissing))
    }

    // MARK: Special files

    private func fifoFixture() throws -> (LocalFixture, LocalFileOps, URL) {
        let fx = try LocalFixture()
        try FileManager.default.createDirectory(at: fx.root.appendingPathComponent("a"), withIntermediateDirectories: true)
        let fifo = fx.root.appendingPathComponent("a/pipe.JPG")
        #expect(mkfifo(fifo.path, 0o644) == 0)
        let ops = LocalFileOps(access: PlainURLRoot(fx.root), writer: AtomicFileWriter(), log: NullLogSink())
        return (fx, ops, fifo)
    }

    /// Runs `body` on its own thread and fails instead of hanging when it blocks; a blocked open is
    /// released afterwards. A dedicated thread starts at once, where a busy shared queue could delay the
    /// work past the timeout and look like a blocked open.
    private func finishes(_ fifo: URL, _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            body()
            done.signal()
        }.start()
        if done.wait(timeout: .now() + 10) == .success { return true }
        let release = open(fifo.path, O_RDWR | O_NONBLOCK)
        if release >= 0 { close(release) }
        _ = done.wait(timeout: .now() + 5)
        return false
    }

    @Test func fifoAtAnAppPathIsRejectedWithoutBlocking() throws {
        let (_, ops, fifo) = try fifoFixture()
        let outcomes = Locked<[String]>([])
        let returned = finishes(fifo) {
            func record(_ work: () throws -> Void) {
                do {
                    try work()
                    outcomes.set(outcomes.value + ["no error"])
                } catch let error as DestinationError {
                    outcomes.set(outcomes.value + ["\(error)"])
                } catch {
                    outcomes.set(outcomes.value + ["other"])
                }
            }
            record { _ = try ops.contentHash("a/pipe.JPG") }
            record { _ = try ops.readSmallFile("a/pipe.JPG", maxBytes: 1024) }
            record { _ = try ops.probe("a/pipe.JPG") }
        }
        #expect(returned)
        #expect(outcomes.value == Array(repeating: "itemRejected(not a regular file)", count: 3))
    }

    @Test func fifoIsNotListed() async throws {
        let (fx, _, _) = try fifoFixture()
        try fx.write("a/real.JPG", "owner")
        let items = try await collect(fx.destination.list(under: nil))
        #expect(items.map(\.remoteId).sorted() == ["a", "a/real.JPG"])
    }
}
