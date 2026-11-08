import Foundation
import PhotoVaultCore

/// Scoped access to the destination's root folder. The URL is valid only inside `body`.
public protocol RootAccess: Sendable {
    /// Throws `DestinationError.bookmarkInvalid` / `.offline` when the root cannot be reached.
    func withRoot<T>(_ body: (URL) throws -> T) throws -> T
}

/// A fixed folder URL (tests, non-sandboxed use).
public struct PlainURLRoot: RootAccess {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    public func withRoot<T>(_ body: (URL) throws -> T) throws -> T { try body(url) }
}

/// An app-scoped security-scoped bookmark (FR-70, FR-75). A stale bookmark is re-created and handed to
/// `onRefresh` so the caller can persist it; one that cannot be resolved or refreshed is `bookmarkInvalid`.
public final class SecurityScopedBookmarkRoot: RootAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var bookmark: Data
    private let onRefresh: @Sendable (Data) -> Void

    public init(bookmark: Data, onRefresh: @escaping @Sendable (Data) -> Void) {
        self.bookmark = bookmark
        self.onRefresh = onRefresh
    }

    /// Creates the bookmark to store when the owner picks a folder.
    public static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw DestinationError.bookmarkInvalid
        }
    }

    public func withRoot<T>(_ body: (URL) throws -> T) throws -> T {
        let data = lock.withLock { bookmark }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            throw DestinationError.offline
        } catch {
            throw DestinationError.bookmarkInvalid
        }
        guard url.startAccessingSecurityScopedResource() else { throw DestinationError.bookmarkInvalid }
        defer { url.stopAccessingSecurityScopedResource() }
        if stale {
            guard let fresh = try? Self.makeBookmark(for: url) else { throw DestinationError.bookmarkInvalid }
            lock.withLock { bookmark = fresh }
            onRefresh(fresh)
        }
        return try body(url)
    }
}
