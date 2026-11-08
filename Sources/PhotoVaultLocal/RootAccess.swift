import Foundation
import PhotoVaultCore

/// Scoped access to the destination's root folder. The URL is valid only inside `body`.
public protocol RootAccess: Sendable {
    /// Throws `DestinationError.bookmarkInvalid` / `.offline` / `.rootMissing` / `.rootTrashed` when the root cannot be used.
    func withRoot<T>(_ body: (URL) throws -> T) throws -> T
}

/// A fixed folder URL (tests, non-sandboxed use).
public struct PlainURLRoot: RootAccess {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    public func withRoot<T>(_ body: (URL) throws -> T) throws -> T { try body(url) }
}

/// An app-scoped security-scoped bookmark (FR-70, FR-75). The bookmark is resolved without mounting or UI
/// and the result (URL plus open security scope) is reused for `cacheWindow`, so a batch of operations
/// resolves once. A stale bookmark is re-created and handed to `onRefresh`, unless the folder now sits in
/// a Trash. One that cannot be resolved or refreshed is `bookmarkInvalid`.
public final class SecurityScopedBookmarkRoot: RootAccess, @unchecked Sendable {
    public static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]

    /// One resolved URL with its open security scope; the scope closes when it is retired and unused.
    private final class Lease {
        let url: URL
        let expires: Date
        var uses = 0
        var retired = false
        init(url: URL, expires: Date) { self.url = url; self.expires = expires }
    }

    private let lock = NSLock()
    private var bookmark: Data
    private var current: Lease?
    private let cacheWindow: TimeInterval
    private let onRefresh: @Sendable (Data) -> Void
    private let volumes: any VolumeLookup
    private(set) var resolveCount = 0

    public convenience init(bookmark: Data, cacheWindow: TimeInterval = 30, onRefresh: @escaping @Sendable (Data) -> Void) {
        self.init(bookmark: bookmark, cacheWindow: cacheWindow, volumes: SystemVolumeLookup(), onRefresh: onRefresh)
    }

    init(bookmark: Data, cacheWindow: TimeInterval = 30, volumes: any VolumeLookup, onRefresh: @escaping @Sendable (Data) -> Void) {
        self.bookmark = bookmark
        self.volumes = volumes
        self.cacheWindow = cacheWindow
        self.onRefresh = onRefresh
    }

    deinit { current?.url.stopAccessingSecurityScopedResource() }

    /// Creates the bookmark to store when the owner picks a folder.
    public static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeURLForRemountingKey, .pathKey], relativeTo: nil)
        } catch {
            throw DestinationError.bookmarkInvalid
        }
    }

    public func withRoot<T>(_ body: (URL) throws -> T) throws -> T {
        let lease = try acquire()
        defer { release(lease) }
        return try body(lease.url)
    }

    private func acquire() throws -> Lease {
        lock.lock()
        defer { lock.unlock() }
        if let current, current.expires > Date() {
            current.uses += 1
            return current
        }
        if let old = current { retire(old) }
        current = nil
        let lease = try resolve()
        lease.uses = 1
        current = lease
        return lease
    }

    private func release(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        lease.uses -= 1
        if lease.retired, lease.uses == 0 { lease.url.stopAccessingSecurityScopedResource() }
    }

    /// Caller holds `lock`.
    private func retire(_ lease: Lease) {
        lease.retired = true
        if lease.uses == 0 { lease.url.stopAccessingSecurityScopedResource() }
    }

    /// Caller holds `lock`.
    private func resolve() throws -> Lease {
        resolveCount += 1
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: Self.resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            let stored = URL.resourceValues(forKeys: [.pathKey, .volumeUUIDStringKey, .volumeURLForRemountingKey], fromBookmarkData: bookmark)
            throw RootState.missingError(path: stored?.path, bookmarkVolumeUUID: stored?.volumeUUIDString,
                                         bookmarkRemountURL: stored?.volumeURLForRemounting?.absoluteString, volumes: volumes)
        } catch {
            throw DestinationError.bookmarkInvalid
        }
        guard url.startAccessingSecurityScopedResource() else { throw DestinationError.bookmarkInvalid }
        if RootState.isInTrash(url) {
            url.stopAccessingSecurityScopedResource()
            throw DestinationError.rootTrashed
        }
        if stale {
            guard let fresh = try? Self.makeBookmark(for: url) else {
                url.stopAccessingSecurityScopedResource()
                throw DestinationError.bookmarkInvalid
            }
            bookmark = fresh
            onRefresh(fresh)
        }
        return Lease(url: url, expires: Date().addingTimeInterval(cacheWindow))
    }
}
