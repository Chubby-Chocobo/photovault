import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultLocal

@Suite struct LocalRootStateTests {
    private func makeRoot() throws -> (base: URL, root: URL, bookmark: Data) {
        let base = try TestFiles.temporaryDirectory("pv-root").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root, try SecurityScopedBookmarkRoot.makeBookmark(for: root))
    }

    @Test func trashPathsAreRecognised() {
        #expect(RootState.isInTrash(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash/Backup")))
        #expect(RootState.isInTrash(URL(fileURLWithPath: "/Volumes/NAS/.Trashes/501/Backup")))
        #expect(!RootState.isInTrash(URL(fileURLWithPath: "/Volumes/NAS/Backup")))
    }

    @Test func missingVersusOffline() {
        #expect(RootState.missingError(path: "/Volumes/pv-absent-volume/x") == .offline)
        #expect(RootState.missingError(path: "/tmp/pv-absent-folder") == .rootMissing)
        #expect(RootState.missingError(path: nil) == .offline)
    }

    @Test func deletedFolderResolvesToRootMissing() throws {
        let fixture = try makeRoot()
        try FileManager.default.removeItem(at: fixture.root)
        let access = SecurityScopedBookmarkRoot(bookmark: fixture.bookmark, onRefresh: { _ in })
        #expect(throws: DestinationError.rootMissing) { try access.withRoot { _ in () } }
    }

    @Test func folderMovedToTrashIsNotFollowedOrRefreshed() async throws {
        let fixture = try makeRoot()
        let trash = fixture.base.appendingPathComponent(".Trashes/501", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.root, to: trash.appendingPathComponent("backup"))
        let refreshed = Locked<Bool>(false)
        let access = SecurityScopedBookmarkRoot(bookmark: fixture.bookmark, onRefresh: { _ in refreshed.set(true) })
        let destination = LocalFolderDestination(id: .local(), root: access)
        #expect(await destination.checkAvailability() == .paused(.rootTrashed))
        #expect(!refreshed.value)
    }

    @Test func resolutionIsCachedForTheWindow() throws {
        let fixture = try makeRoot()
        let cached = SecurityScopedBookmarkRoot(bookmark: fixture.bookmark, cacheWindow: 60, onRefresh: { _ in })
        for _ in 0..<5 { try cached.withRoot { _ in () } }
        #expect(cached.resolveCount == 1)
        let uncached = SecurityScopedBookmarkRoot(bookmark: fixture.bookmark, cacheWindow: 0, onRefresh: { _ in })
        for _ in 0..<3 { try uncached.withRoot { _ in () } }
        #expect(uncached.resolveCount == 3)
    }

    @Test func resolutionNeverMounts() {
        #expect(SecurityScopedBookmarkRoot.resolutionOptions.contains(.withoutMounting))
        #expect(SecurityScopedBookmarkRoot.resolutionOptions.contains(.withoutUI))
    }
}

final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}
