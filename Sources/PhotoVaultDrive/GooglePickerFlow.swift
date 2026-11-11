import Foundation
import PhotoVaultCore

/// What the owner chose and the grant that lets the app read it.
public struct PickerResult: Sendable, CustomStringConvertible {
    public var pickedIds: [String]
    public var refreshToken: String
    public var accessToken: String
    public var expiresAt: Date
    /// Display only; nil when Google did not answer `about.get`.
    public var email: String?
    public var description: String { "PickerResult(<redacted>)" }
}

public enum PickerError: Error, Equatable, Sendable {
    case browserUnavailable
    /// The owner closed the picker or refused consent.
    case cancelled
    case timedOut
    /// Consent was given but nothing was selected.
    case nothingPicked
    case tokenMissing
    /// Google's consent was given without the permission to read Drive files (the owner cleared that box).
    case readAccessDenied
    /// Consent was given without the permission for the files the owner picks (the owner cleared that box).
    case pickAccessDenied
    /// The selection was too large for the redirect to carry.
    case selectionTooLarge
    /// The read step was signed in with another Google account than the one that picked the folder.
    case accountMismatch
}

/// Google's desktop Picker flow, in two consents for the same account.
/// 1. The Picker: OAuth with `drive.file` alone plus `trigger_onepick`. Google's desktop Picker allows no other scope with it.
///    It returns the picked ids and a token that only identifies the account.
/// 2. The read: a plain OAuth with `drive.readonly` alone, `login_hint` set to that account, so the folders picked can be listed
///    to their depth (`drive.file` does not reveal a folder's children). Only this grant is kept; the step 1 token is dropped, not revoked,
///    because a revoke ends every grant of the client for that account, including a backup destination.
/// Only imports use it; the backup destination stays `drive.file`. The loopback redirect carries `picked_file_ids` in step 1.
public struct GooglePickerFlow: Sendable {
    static let readScope = "https://www.googleapis.com/auth/drive.readonly"
    public static let scope = OAuthClient.fileScope
    /// What the loopback request line can carry with room to spare: an id is at most about 45 bytes and its
    /// comma may arrive as `%2C`, so 48 bytes each, after 4 KiB for the other query items. More than this is refused.
    static let maxPickedIds = (LoopbackRequestParser.maxRequestBytes - 4096) / 48
    /// Picking many photos across folders takes a while; the selection is lost when this runs out.
    public static let pickTimeout: TimeInterval = 20 * 60

    private let config: OAuthConfig
    private let transport: any HTTPTransport
    private let clock: any Clock
    private let openURL: URLOpening
    private let loopbackTimeout: TimeInterval
    private let onReadStep: @Sendable () -> Void

    /// - Parameter onReadStep: called when the second consent is about to open, so the app can say "step 2 of 2".
    public init(config: OAuthConfig, transport: any HTTPTransport, clock: any Clock = SystemClock(),
                openURL: @escaping URLOpening, loopbackTimeout: TimeInterval = GooglePickerFlow.pickTimeout,
                onReadStep: @escaping @Sendable () -> Void = {}) {
        self.config = config
        self.transport = transport
        self.clock = clock
        self.openURL = openURL
        self.loopbackTimeout = loopbackTimeout
        self.onReadStep = onReadStep
    }

    public static func authorizationURL(clientID: String, redirectURI: String, state: String, challenge: String,
                                        allowMultiple: Bool = true, allowFolders: Bool = true) -> URL {
        var fields: [(String, String)] = [
            ("client_id", clientID), ("redirect_uri", redirectURI), ("response_type", "code"),
            ("scope", scope), ("state", state), ("code_challenge", challenge), ("code_challenge_method", "S256"),
            ("access_type", "offline"), ("prompt", "select_account consent"), ("trigger_onepick", "true"),
        ]
        if allowMultiple { fields.append(("allow_multiple", "true")) }
        if allowFolders { fields.append(("allow_folder_selection", "true")) }
        return url(fields)
    }

    /// The read step: `drive.readonly` only, no Picker parameters, the account of the pick as `login_hint`.
    public static func readAuthorizationURL(clientID: String, redirectURI: String, state: String, challenge: String,
                                            loginHint: String?) -> URL {
        var fields: [(String, String)] = [
            ("client_id", clientID), ("redirect_uri", redirectURI), ("response_type", "code"),
            ("scope", readScope), ("state", state), ("code_challenge", challenge), ("code_challenge_method", "S256"),
            ("access_type", "offline"), ("prompt", "consent"),
        ]
        if let loginHint, !loginHint.isEmpty { fields.append(("login_hint", loginHint)) }
        return url(fields)
    }

    private static func url(_ fields: [(String, String)]) -> URL {
        var components = URLComponents(url: OAuthConfig.authEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = FormEncoding.encode(fields)
        return components.url!
    }

    /// Interactive; call only from an explicit user action. Network and token failures are `DestinationError`.
    /// The result carries the `drive.readonly` grant.
    public func run() async throws -> PickerResult {
        let oauth = OAuthClient(config: config, transport: transport, clock: clock, openURL: openURL)
        let (ids, account) = try await pickStep(oauth)
        onReadStep()
        let read = try await readStep(oauth, account: account)
        return PickerResult(pickedIds: ids, refreshToken: read.refresh, accessToken: read.tokens.accessToken,
                            expiresAt: read.tokens.expiresAt, email: account?.email)
    }

    // MARK: Steps

    private struct Account: Sendable { var email: String?; var permissionId: String? }

    private struct Authorized {
        var code: String
        var verifier: String
        var redirectURI: String
        var server: LoopbackRedirectServer
    }

    /// Opens `makeURL`'s page and waits for the redirect. The caller answers the browser through `server`.
    private func authorize(_ makeURL: (_ redirectURI: String, _ state: String, _ challenge: String) -> URL) async throws -> Authorized {
        let pkce = try PKCE()
        let state = try PKCE.randomState()
        let server = try LoopbackRedirectServer(expectedState: state, timeout: loopbackTimeout)
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)\(LoopbackRequestParser.callbackPath)"
        guard await openURL(makeURL(redirectURI, state, pkce.challenge)) else {
            server.cancel()
            throw PickerError.browserUnavailable
        }
        do {
            let code = try await server.awaitCode()
            return Authorized(code: code, verifier: pkce.verifier, redirectURI: redirectURI, server: server)
        } catch let error as LoopbackError {
            switch error {
            case .timeout: throw PickerError.timedOut
            case .cancelled, .authorizationDenied("access_denied"): throw PickerError.cancelled
            case .requestTooLarge: throw PickerError.selectionTooLarge
            default: throw DestinationError.itemRejected(reason: "picker redirect \(error)")
            }
        }
    }

    private func pickStep(_ oauth: OAuthClient) async throws -> (ids: [String], account: Account?) {
        let step = try await authorize { redirectURI, state, challenge in
            Self.authorizationURL(clientID: config.clientID, redirectURI: redirectURI, state: state, challenge: challenge)
        }
        do {
            let ids = try Self.parseIds(step.server.receivedCallback?.pickedFileIds)
            guard !ids.isEmpty else { throw PickerError.nothingPicked }
            let tokens: OAuthTokens
            do {
                tokens = try await oauth.exchange(code: step.code, verifier: step.verifier, redirectURI: step.redirectURI)
            } catch DestinationError.itemRejected(let reason) where reason == OAuthClient.fileScopeMissing {
                throw PickerError.pickAccessDenied
            }
            let account = await Self.account(transport: transport, accessToken: tokens.accessToken)
            step.server.respond(.success)
            return (ids, account)
        } catch {
            step.server.respond(error as? PickerError == .selectionTooLarge ? .selectionTooLarge : .failed)
            throw error
        }
    }

    private func readStep(_ oauth: OAuthClient, account: Account?) async throws -> (tokens: OAuthTokens, refresh: String) {
        let step = try await authorize { redirectURI, state, challenge in
            Self.readAuthorizationURL(clientID: config.clientID, redirectURI: redirectURI, state: state, challenge: challenge,
                                      loginHint: account?.email)
        }
        do {
            let tokens = try await oauth.exchange(code: step.code, verifier: step.verifier, redirectURI: step.redirectURI, requiredScope: nil)
            // Google shows the permission as a box that can be cleared; without it a picked folder lists as empty.
            guard tokens.scopes.contains(Self.readScope) else { throw PickerError.readAccessDenied }
            guard let refresh = tokens.refreshToken else { throw PickerError.tokenMissing }
            if let account {
                let signedIn = await Self.account(transport: transport, accessToken: tokens.accessToken)
                guard Self.sameAccount(account, signedIn) else { throw PickerError.accountMismatch }
            }
            step.server.respond(.success)
            return (tokens, refresh)
        } catch {
            step.server.respond(.failed)
            throw error
        }
    }

    /// The Drive permission id is stable and always present; the e-mail is the fallback when either side lacks it.
    /// An account that cannot be read now counts as different.
    private static func sameAccount(_ expected: Account, _ actual: Account?) -> Bool {
        guard let actual else { return false }
        if let a = expected.permissionId, let b = actual.permissionId { return a == b }
        if let a = expected.email?.lowercased(), let b = actual.email?.lowercased() { return a == b }
        return false
    }

    /// Ids are opaque Drive ids: letters, digits, `-` and `_`. Anything else is dropped, duplicates collapse.
    /// More than `maxPickedIds` valid ids throw `selectionTooLarge`; an id is never dropped silently.
    static func parseIds(_ raw: String?) throws -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for part in (raw ?? "").split(separator: ",") {
            let id = part.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, id.utf8.count <= 128,
                  id.unicodeScalars.allSatisfy({ ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "-" || $0 == "_" }),
                  seen.insert(id).inserted else { continue }
            guard ids.count < maxPickedIds else { throw PickerError.selectionTooLarge }
            ids.append(id)
        }
        return ids
    }

    private static func account(transport: any HTTPTransport, accessToken: String) async -> Account? {
        struct About: Decodable { struct User: Decodable { var emailAddress: String?; var permissionId: String? }; var user: User? }
        let http = DriveHTTP(transport: transport, auth: FixedTokenAuth(token: accessToken))
        let url = DriveURL.make(DriveURL.api, "/about", [("fields", "user(emailAddress,permissionId)")])
        guard let user = try? await http.sendJSON(About.self, url, method: "GET").user,
              user.emailAddress != nil || user.permissionId != nil else { return nil }
        return Account(email: user.emailAddress, permissionId: user.permissionId)
    }
}

/// A token that is used as is; a 401 cannot be refreshed.
struct FixedTokenAuth: DriveAuthorizing {
    let token: String
    func accessToken() async throws -> String { token }
    func refreshAfterUnauthorized(rejected: String) async throws -> String { throw DestinationError.reauthRequired }
}
