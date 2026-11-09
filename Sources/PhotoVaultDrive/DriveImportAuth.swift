import Foundation
import PhotoVaultCore

/// Authorizes one import. Its refresh token lives in the Keychain under `import-<sourceId>`, so an
/// import keeps working whatever account the app's own Drive destination uses.
/// A dead grant (`invalid_grant`, or no token in the Keychain) surfaces as `DestinationError.reauthRequired`.
public actor DriveImportAuth: DriveAuthorizing {
    private static let expirySkew: TimeInterval = 60

    public static func keychainAccount(for sourceId: SourceID) -> String { CloudTokenAccount.importGrant(sourceId) }

    /// Keeps the grant of a finished pick for `sourceId`.
    public static func store(refreshToken: String, for sourceId: SourceID, in keychain: any KeychainStore) throws {
        try keychain.write(Data(refreshToken.utf8), account: keychainAccount(for: sourceId))
    }

    public static func hasGrant(for sourceId: SourceID, in keychain: any KeychainStore) -> Bool {
        (try? keychain.read(account: keychainAccount(for: sourceId))) != nil
    }

    public static func removeGrant(for sourceId: SourceID, from keychain: any KeychainStore) throws {
        try keychain.delete(account: keychainAccount(for: sourceId))
    }

    private let account: String
    private let oauth: OAuthClient
    private let keychain: any KeychainStore
    private let clock: any Clock
    private var cached: (token: String, expiresAt: Date)?
    private var refreshing: Task<OAuthTokens, any Error>?

    /// - Parameter initial: the access token the pick just produced, so the first call needs no refresh.
    public init(sourceId: SourceID, oauth: OAuthClient, keychain: any KeychainStore, clock: any Clock = SystemClock(),
                initial: (accessToken: String, expiresAt: Date)? = nil) {
        account = Self.keychainAccount(for: sourceId)
        self.oauth = oauth
        self.keychain = keychain
        self.clock = clock
        cached = initial.map { ($0.accessToken, $0.expiresAt) }
    }

    public func accessToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(clock.now) > Self.expirySkew { return cached.token }
        return try await refresh()
    }

    public func refreshAfterUnauthorized(rejected: String) async throws -> String {
        if let cached, cached.token != rejected, cached.expiresAt > clock.now { return cached.token }
        cached = nil
        return try await refresh()
    }

    private func refresh() async throws -> String {
        let task: Task<OAuthTokens, any Error>
        if let refreshing {
            task = refreshing
        } else {
            guard let data = try keychain.read(account: account), let refreshToken = String(data: data, encoding: .utf8) else {
                throw DestinationError.reauthRequired
            }
            task = Task { [oauth] in try await oauth.refresh(refreshToken: refreshToken) }
            refreshing = task
        }
        defer { if refreshing == task { refreshing = nil } }
        let tokens = try await task.value
        cached = (tokens.accessToken, tokens.expiresAt)
        if let rotated = tokens.refreshToken { try keychain.write(Data(rotated.utf8), account: account) }
        return tokens.accessToken
    }
}
