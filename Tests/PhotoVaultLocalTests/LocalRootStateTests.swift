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

    private struct FakeVolumes: VolumeLookup {
        var uuids: [String: String] = [:]
        var remountURLs: [String: String] = [:]

        private func nearest(_ table: [String: String], _ path: String) -> String? {
            table.filter { $0.key == "/" || path == $0.key || path.hasPrefix($0.key + "/") }.max { $0.key.count < $1.key.count }?.value
        }

        func mountedVolume(containing path: String) -> MountedVolume {
            MountedVolume(uuid: nearest(uuids, path), remountURL: nearest(remountURLs, path))
        }
    }

    @Test func twoSMBSharesMountedAtTheSamePathAreTold() {
        let path = "/Volumes/photo/backup"
        let stored = "smb://nas-a/photo"
        let same = FakeVolumes(uuids: ["/": "BOOT"], remountURLs: ["/Volumes/photo": stored])
        let otherServer = FakeVolumes(uuids: ["/": "BOOT"], remountURLs: ["/Volumes/photo": "smb://nas-b/photo"])
        let unmounted = FakeVolumes(uuids: ["/": "BOOT"])
        #expect(RootState.missingError(path: path, bookmarkRemountURL: stored, volumes: same) == .rootMissing)
        #expect(RootState.missingError(path: path, bookmarkRemountURL: stored, volumes: otherServer) == .offline)
        #expect(RootState.missingError(path: path, bookmarkRemountURL: stored, volumes: unmounted) == .offline)
    }

    @Test func bookmarkCarriesTheRemountURLWhenTheVolumeHasOne() throws {
        let fixture = try makeRoot()
        let stored = URL.resourceValues(forKeys: [.volumeURLForRemountingKey], fromBookmarkData: fixture.bookmark)
        let live = try fixture.root.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting
        #expect(stored?.volumeURLForRemounting == live)
    }

    @Test func twoVolumesWithTheSameNameAreTold() {
        let bookmarked = "UUID-OF-NAS-A"
        let path = "/Volumes/Photos/backup"
        let sameVolume = FakeVolumes(uuids: ["/": "BOOT", "/Volumes/Photos": bookmarked])
        let otherVolume = FakeVolumes(uuids: ["/": "BOOT", "/Volumes/Photos": "UUID-OF-NAS-B"])
        let unmounted = FakeVolumes(uuids: ["/": "BOOT"])
        #expect(RootState.missingError(path: path, bookmarkVolumeUUID: bookmarked, volumes: sameVolume) == .rootMissing)
        #expect(RootState.missingError(path: path, bookmarkVolumeUUID: bookmarked, volumes: otherVolume) == .offline)
        #expect(RootState.missingError(path: path, bookmarkVolumeUUID: bookmarked, volumes: unmounted) == .offline)
    }

    @Test func rootsOutsideVolumesFollowTheirVolume() {
        let boot = FakeVolumes(uuids: ["/": "BOOT"])
        #expect(RootState.missingError(path: "/Users/me/backup", bookmarkVolumeUUID: "BOOT", volumes: boot) == .rootMissing)
        let autofs = FakeVolumes(uuids: ["/": "BOOT"])
        #expect(RootState.missingError(path: "/mnt/nas/backup", bookmarkVolumeUUID: "NAS", volumes: autofs) == .offline)
    }

    @Test func bookmarkedRootOnAnotherVolumeIsOffline() throws {
        let fixture = try makeRoot()
        try FileManager.default.removeItem(at: fixture.root)
        let stored = URL.resourceValues(forKeys: [.volumeUUIDStringKey], fromBookmarkData: fixture.bookmark)?.volumeUUIDString
        let uuid = try #require(stored)
        let same = SecurityScopedBookmarkRoot(bookmark: fixture.bookmark, volumes: FakeVolumes(uuids: ["/": uuid]), onRefresh: { _ in })
        #expect(throws: DestinationError.rootMissing) { try same.withRoot { _ in () } }
        let other = SecurityScopedBookmarkRoot(bookmark: fixture.bookmark, volumes: FakeVolumes(uuids: ["/": "OTHER"]), onRefresh: { _ in })
        #expect(throws: DestinationError.offline) { try other.withRoot { _ in () } }
    }

    @Test func missingRootClearsWhenTheFolderReturns() async throws {
        let fixture = try makeRoot()
        let access = SecurityScopedBookmarkRoot(bookmark: fixture.bookmark, cacheWindow: 0, onRefresh: { _ in })
        let destination = LocalFolderDestination(id: .local(), root: access)
        #expect(await destination.checkAvailability() == .active)
        try FileManager.default.removeItem(at: fixture.root)
        #expect(await destination.checkAvailability() == .paused(.rootMissing))
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        #expect(await destination.checkAvailability() == .active)
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
