import Foundation
import PhotoVaultCore

/// What `DriveAPI` needs from authentication.
public protocol DriveAuthorizing: Sendable {
    func accessToken() async throws -> String
    /// Called after a 401. Refreshes once; if another caller already refreshed, returns that token.
    func refreshAfterUnauthorized(rejected: String) async throws -> String
}

/// A completed OAuth sign-in that is held in memory only. Nothing is written to the Keychain and no
/// live token changes until `GoogleAuthSession.commitAccountChange(_:)` (FR-08: confirm, then reset).
public struct StagedAccount: Sendable, CustomStringConvertible {
    public let identity: GoogleIdentity
    fileprivate let id = UUID()
    fileprivate let refreshToken: String
    fileprivate let accessToken: String
    fileprivate let expiresAt: Date
    public var description: String { "StagedAccount(<redacted>)" }
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
    /// Bumped whenever the live credentials are replaced or removed; a refresh that started under an
    /// older generation is discarded so it can never write stale tokens.
    private var generation = 0
    private var pendingStage: UUID?

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
        try install(refreshToken: refresh, accessToken: result.tokens.accessToken, expiresAt: result.tokens.expiresAt)
        log.log(.info, category: "drive.auth", "signed in")
        return result.identity
    }

    /// Runs OAuth and validates the ID token, keeping the tokens in memory. The live credentials are untouched.
    public func beginAccountChange() async throws -> StagedAccount {
        let result = try await oauth.signIn()
        guard let refresh = result.tokens.refreshToken else {
            throw DestinationError.itemRejected(reason: "refresh token missing")
        }
        let staged = StagedAccount(identity: result.identity, refreshToken: refresh,
                                   accessToken: result.tokens.accessToken, expiresAt: result.tokens.expiresAt)
        pendingStage = staged.id
        return staged
    }

    /// Writes the staged refresh token to the Keychain and makes it live. Fails without side effects when
    /// the Keychain write fails or the stage was discarded or superseded.
    public func commitAccountChange(_ staged: StagedAccount) async throws {
        guard pendingStage == staged.id else { throw DestinationError.itemRejected(reason: "account change no longer pending") }
        try install(refreshToken: staged.refreshToken, accessToken: staged.accessToken, expiresAt: staged.expiresAt)
        pendingStage = nil
        log.log(.info, category: "drive.auth", "account changed")
    }

    /// Drops a staged sign-in. Live credentials are not touched, so a cancelled change leaves the old account working.
    public func discardAccountChange(_ staged: StagedAccount) {
        if pendingStage == staged.id { pendingStage = nil }
    }

    private func install(refreshToken: String, accessToken: String, expiresAt: Date) throws {
        try keychain.write(Data(refreshToken.utf8), account: Self.refreshAccount)
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        cached = (accessToken, expiresAt)
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
        generation += 1
        pendingStage = nil
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
        let started = generation
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
        let tokens: OAuthTokens
        do { tokens = try await task.value } catch {
            // Credentials changed while waiting: the outcome belongs to the old account, so start over.
            if started != generation { return try await accessToken() }
            throw error
        }
        if started != generation { return try await accessToken() }
        cached = (tokens.accessToken, tokens.expiresAt)
        if let rotated = tokens.refreshToken { try keychain.write(Data(rotated.utf8), account: Self.refreshAccount) }
        return tokens.accessToken
    }
}
