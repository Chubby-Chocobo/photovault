import Foundation
import PhotoVaultCore
import PhotoVaultDrive

/// Hands out a valid access token for API calls.
public protocol DropboxAccessTokenProviding: Sendable {
    /// `forceRefresh` discards the cached token (the server said it expired).
    /// Throws `SourceError.accessRevoked` when the grant is gone and `.unavailable` when the network is.
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// Keeps one refresh token in the Keychain and the short-lived access token in memory.
public actor DropboxTokenAuthorizer: DropboxAccessTokenProviding {
    private static let expirySlack: TimeInterval = 60

    private let auth: DropboxAuth
    private let keychain: any KeychainStore
    private let keychainAccount: String
    private let clock: any Clock
    private var cached: DropboxAccessToken?

    public init(auth: DropboxAuth, keychain: any KeychainStore, keychainAccount: String, clock: any Clock = SystemClock()) {
        self.auth = auth
        self.keychain = keychain
        self.keychainAccount = keychainAccount
        self.clock = clock
    }

    /// Stores the refresh token of a fresh sign-in and keeps its access token for the first calls.
    public func store(_ signIn: DropboxSignIn) throws {
        try Self.keychainCall { try keychain.write(Data(signIn.refreshToken.utf8), account: keychainAccount) }
        cached = signIn.accessToken
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached, cached.expiresAt.timeIntervalSince(clock.now) > Self.expirySlack { return cached.token }
        let stored = try Self.keychainCall { try keychain.read(account: keychainAccount) }
        guard let stored, let refreshToken = String(data: stored, encoding: .utf8), !refreshToken.isEmpty else {
            throw SourceError.accessRevoked
        }
        let fresh = try await auth.refresh(refreshToken: refreshToken)
        cached = fresh
        return fresh.token
    }

    private static func keychainCall<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as DestinationError {
            if case .reauthRequired = error { throw SourceError.accessRevoked }
            throw SourceError.unavailable
        }
    }
}
