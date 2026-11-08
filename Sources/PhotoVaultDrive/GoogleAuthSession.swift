import Foundation
import PhotoVaultCore

/// What `DriveAPI` needs from authentication.
public protocol DriveAuthorizing: Sendable {
    func accessToken() async throws -> String
    /// Called after a 401. Refreshes once; if another caller already refreshed, returns that token.
    func refreshAfterUnauthorized(rejected: String) async throws -> String
}

/// Holds the access token in memory and the refresh token in the Keychain.
public actor GoogleAuthSession: DriveAuthorizing {
    public static let refreshAccount = "refresh-token"
    private static let expirySkew: TimeInterval = 60

    private let oauth: OAuthClient
    private let keychain: any KeychainStore
    private let clock: any Clock
    private let log: any LogSink
    private var cached: (token: String, expiresAt: Date)?
    private var refreshing: Task<OAuthTokens, any Error>?

    public init(oauth: OAuthClient, keychain: any KeychainStore, clock: any Clock = SystemClock(), log: any LogSink = NullLogSink()) {
        self.oauth = oauth
        self.keychain = keychain
        self.clock = clock
        self.log = log
    }

    /// Explicit, user-initiated sign-in. Stores the refresh token before returning.
    public func signIn() async throws -> GoogleIdentity {
        let result = try await oauth.signIn()
        guard let refresh = result.tokens.refreshToken else {
            throw DestinationError.itemRejected(reason: "refresh token missing")
        }
        try keychain.write(Data(refresh.utf8), account: Self.refreshAccount)
        cached = (result.tokens.accessToken, result.tokens.expiresAt)
        log.log(.info, category: "drive.auth", "signed in")
        return result.identity
    }

    public var hasCredentials: Bool { (try? keychain.read(account: Self.refreshAccount)) != nil }

    public func accessToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(clock.now) > Self.expirySkew { return cached.token }
        return try await refresh()
    }

    public func refreshAfterUnauthorized(rejected: String) async throws -> String {
        if let cached, cached.token != rejected, cached.expiresAt > clock.now { return cached.token }
        cached = nil
        return try await refresh()
    }

    /// Deletes the Keychain item first and unconditionally, then revokes best-effort.
    public func signOut() async throws {
        let refreshToken = (try? keychain.read(account: Self.refreshAccount)).flatMap { String(data: $0, encoding: .utf8) }
        let access = cached?.token
        cached = nil
        refreshing?.cancel()
        refreshing = nil
        var deleteError: (any Error)?
        do { try keychain.delete(account: Self.refreshAccount) } catch { deleteError = error }
        if let token = refreshToken ?? access {
            do { try await oauth.revoke(token: token) } catch {
                log.log(.notice, category: "drive.auth", "revoke failed; local credentials already removed")
            }
        }
        if let deleteError { throw deleteError }
        log.log(.info, category: "drive.auth", "signed out")
    }

    private func refresh() async throws -> String {
        let task: Task<OAuthTokens, any Error>
        if let refreshing {
            task = refreshing
        } else {
            guard let data = try keychain.read(account: Self.refreshAccount),
                  let refreshToken = String(data: data, encoding: .utf8) else {
                throw DestinationError.reauthRequired
            }
            task = Task { [oauth] in try await oauth.refresh(refreshToken: refreshToken) }
            refreshing = task
        }
        defer { if refreshing == task { refreshing = nil } }
        let tokens = try await task.value
        cached = (tokens.accessToken, tokens.expiresAt)
        if let rotated = tokens.refreshToken { try keychain.write(Data(rotated.utf8), account: Self.refreshAccount) }
        return tokens.accessToken
    }
}
