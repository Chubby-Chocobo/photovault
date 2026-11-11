import Foundation
import PhotoVaultCore

public struct OAuthConfig: Sendable {
    public var clientID: String
    /// Google "Desktop" clients carry a secret that is not confidential; still never logged.
    public var clientSecret: String?
    public static let scopes = "https://www.googleapis.com/auth/drive.file openid email"
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct OAuthTokens: Sendable, CustomStringConvertible {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var idToken: String?
    /// What Google says was granted (empty when it did not say).
    public var scopes: [String] = []
    public var description: String { "OAuthTokens(<redacted>)" }
}

public struct SignInResult: Sendable, CustomStringConvertible {
    public var identity: GoogleIdentity
    public var tokens: OAuthTokens
    public var description: String { "SignInResult(<redacted>)" }
}

/// Opens the authorization URL in the default browser; returns false when it could not.
public typealias URLOpening = @Sendable (URL) async -> Bool

public struct OAuthClient: Sendable {
    private let config: OAuthConfig
    private let transport: any HTTPTransport
    private let clock: any Clock
    private let openURL: URLOpening
    private let loopbackTimeout: TimeInterval

    public init(config: OAuthConfig, transport: any HTTPTransport, clock: any Clock = SystemClock(),
                openURL: @escaping URLOpening, loopbackTimeout: TimeInterval = LoopbackRedirectServer.defaultTimeout) {
        self.config = config
        self.transport = transport
        self.clock = clock
        self.openURL = openURL
        self.loopbackTimeout = loopbackTimeout
    }

    public static func authorizationURL(clientID: String, redirectURI: String, state: String, challenge: String) -> URL {
        let query = FormEncoding.encode([
            ("client_id", clientID), ("redirect_uri", redirectURI), ("response_type", "code"),
            ("scope", OAuthConfig.scopes), ("state", state), ("code_challenge", challenge),
            ("code_challenge_method", "S256"), ("access_type", "offline"), ("prompt", "select_account consent"),
        ])
        var components = URLComponents(url: OAuthConfig.authEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        return components.url!
    }

    /// Interactive sign-in. Called only from an explicit user action, never automatically.
    public func signIn() async throws -> SignInResult {
        let pkce = try PKCE()
        let state = try PKCE.randomState()
        let server = try LoopbackRedirectServer(expectedState: state, timeout: loopbackTimeout)
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)\(LoopbackRequestParser.callbackPath)"
        let url = Self.authorizationURL(clientID: config.clientID, redirectURI: redirectURI, state: state, challenge: pkce.challenge)
        guard await openURL(url) else {
            server.cancel()
            throw DestinationError.transient(reason: "browser could not be opened")
        }
        let code: String
        do { code = try await server.awaitCode() } catch let error as LoopbackError {
            throw error == .timeout || error == .cancelled
                ? DestinationError.transient(reason: "sign-in \(error == .timeout ? "timed out" : "cancelled")")
                : DestinationError.itemRejected(reason: "sign-in \(error)")
        }
        do {
            let tokens = try await exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
            guard let idToken = tokens.idToken else { throw DestinationError.itemRejected(reason: "id token missing") }
            let identity = try IDToken.identity(from: idToken, clientID: config.clientID, now: clock.now)
            // Checked here, not by the caller, so the browser page can say why the sign-in will not last.
            guard tokens.refreshToken != nil else { throw DestinationError.itemRejected(reason: Self.refreshTokenMissing) }
            server.respond(.success)
            return SignInResult(identity: identity, tokens: tokens)
        } catch {
            server.respond(Self.callbackPage(for: error))
            throw error
        }
    }

    /// The browser page for a failed sign-in: the reasons this client writes itself get their own page, anything else the generic one.
    static func callbackPage(for error: any Error) -> CallbackPage {
        guard case .itemRejected(let reason)? = error as? DestinationError else { return .failed }
        switch reason {
        case fileScopeMissing: return .driveScopeMissing
        case refreshTokenMissing: return .persistentSignInMissing
        default: return .failed
        }
    }

    /// - Parameter requiredScope: a scope the response must list (when it lists any); nil skips the check.
    public func exchange(code: String, verifier: String, redirectURI: String,
                         requiredScope: String? = OAuthClient.fileScope) async throws -> OAuthTokens {
        try await tokenRequest([("grant_type", "authorization_code"), ("code", code),
                                ("code_verifier", verifier), ("redirect_uri", redirectURI)], requiredScope: requiredScope)
    }

    /// `invalid_grant` means the refresh token is dead: the user must sign in again.
    /// Any failure that is not invalid_grant, 401, 429, 5xx or a network problem means the stored
    /// grant cannot be used (bad client, scope dropped, malformed reply): destination-level `reauthRequired`.
    public func refresh(refreshToken: String, requiredScope: String? = OAuthClient.fileScope) async throws -> OAuthTokens {
        do {
            return try await tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refreshToken)], requiredScope: requiredScope)
        } catch let error as DestinationError {
            switch error {
            case .reauthRequired, .unauthorized, .rateLimited, .server, .offline, .transient: throw error
            default: throw DestinationError.reauthRequired
            }
        }
    }

    public func revoke(token: String) async throws {
        let (data, response) = try await perform(formRequest(OAuthConfig.revokeEndpoint), form: [("token", token)])
        if let error = Self.error(data, response) { throw error }
    }

    // MARK: Internals

    /// The `itemRejected` reason of a token response that lacks the `drive.file` permission.
    public static let fileScope = "https://www.googleapis.com/auth/drive.file"
    static let fileScopeMissing = "drive.file scope not granted"
    /// The `itemRejected` reason of a sign-in that Google answered without a refresh token.
    static let refreshTokenMissing = "refresh token missing"

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
        var id_token: String?
        var scope: String?
    }

    private func tokenRequest(_ fields: [(String, String)], requiredScope: String?) async throws -> OAuthTokens {
        var form = fields + [("client_id", config.clientID)]
        if let secret = config.clientSecret { form.append(("client_secret", secret)) }
        let (data, response) = try await perform(formRequest(OAuthConfig.tokenEndpoint), form: form)
        if let error = Self.error(data, response) { throw error }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw DestinationError.itemRejected(reason: "token response malformed")
        }
        if let required = requiredScope, let scope = decoded.scope, !scope.split(separator: " ").contains(Substring(required)) {
            throw DestinationError.itemRejected(reason: Self.fileScopeMissing)
        }
        return OAuthTokens(accessToken: decoded.access_token, refreshToken: decoded.refresh_token,
                           expiresAt: clock.now.addingTimeInterval(decoded.expires_in ?? 3600), idToken: decoded.id_token,
                           scopes: decoded.scope?.split(separator: " ").map(String.init) ?? [])
    }

    private func formRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(_ request: URLRequest, form: [(String, String)]) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request, body: .data(Data(FormEncoding.encode(form).utf8)))
        } catch let error as URLError {
            throw DriveTransportError.map(error)
        }
    }

    private static func error(_ data: Data, _ response: HTTPURLResponse) -> DestinationError? {
        guard !(200..<300).contains(response.statusCode) else { return nil }
        struct Body: Decodable { var error: String? }
        let code = (try? JSONDecoder().decode(Body.self, from: data))?.error
        if code == "invalid_grant" { return .reauthRequired }
        return ErrorClassifier.destinationError(httpStatus: response.statusCode, reason: code,
                                                retryAfter: DriveErrorMapper.retryAfter(response))
    }
}

enum FormEncoding {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}
