import Foundation
import PhotoVaultCore
import PhotoVaultDrive

/// Sign-in failures that are not about the network or a dead grant.
public enum DropboxAuthError: Error, Equatable, Sendable {
    case browserUnavailable
    case cancelled
    case timedOut
    /// The owner refused, or the redirect was not the one we started.
    case denied
    case malformedResponse
    /// The fixed redirect port is taken by another program.
    case portInUse
}

public struct DropboxAccessToken: Sendable, CustomStringConvertible {
    public var token: String
    public var expiresAt: Date
    public var description: String { "DropboxAccessToken(<redacted>)" }
}

public struct DropboxSignIn: Sendable, CustomStringConvertible {
    public var accessToken: DropboxAccessToken
    public var refreshToken: String
    public var email: String
    public var description: String { "DropboxSignIn(<redacted>)" }
}

/// PKCE sign-in and token refresh. The redirect URI is fixed because Dropbox compares it exactly.
public struct DropboxAuth: Sendable {
    public static let redirectPort: UInt16 = 53682
    public static let redirectURI = "http://localhost:\(redirectPort)\(LoopbackRequestParser.callbackPath)"
    public static let scopes = "files.metadata.read files.content.read account_info.read"

    private let appKey: String
    private let transport: any HTTPTransport
    private let clock: any Clock
    private let openURL: URLOpening
    private let loopbackTimeout: TimeInterval
    private let port: UInt16

    public init(appKey: String, transport: any HTTPTransport, clock: any Clock = SystemClock(), openURL: @escaping URLOpening,
                loopbackTimeout: TimeInterval = LoopbackRedirectServer.defaultTimeout, port: UInt16 = DropboxAuth.redirectPort) {
        self.appKey = appKey
        self.transport = transport
        self.clock = clock
        self.openURL = openURL
        self.loopbackTimeout = loopbackTimeout
        self.port = port
    }

    public static func authorizationURL(appKey: String, state: String, challenge: String) -> URL {
        let query = DropboxForm.encode([
            ("client_id", appKey), ("response_type", "code"), ("code_challenge", challenge), ("code_challenge_method", "S256"),
            ("token_access_type", "offline"), ("redirect_uri", redirectURI), ("state", state), ("scope", scopes),
        ])
        var components = URLComponents(url: DropboxEndpoint.authorize, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        return components.url!
    }

    /// Interactive sign-in; call only from an explicit owner action.
    public func signIn() async throws -> DropboxSignIn {
        let pkce = try PKCE()
        let state = try PKCE.randomState()
        let server = try LoopbackRedirectServer(expectedState: state, timeout: loopbackTimeout, port: port)
        do { _ = try await server.start() } catch { throw DropboxAuthError.portInUse }
        guard await openURL(Self.authorizationURL(appKey: appKey, state: state, challenge: pkce.challenge)) else {
            server.cancel()
            throw DropboxAuthError.browserUnavailable
        }
        let code: String
        do { code = try await server.awaitCode() } catch let error as LoopbackError {
            switch error {
            case .timeout: throw DropboxAuthError.timedOut
            case .cancelled: throw DropboxAuthError.cancelled
            default: throw DropboxAuthError.denied
            }
        }
        do {
            let reply = try await tokenRequest([
                ("grant_type", "authorization_code"), ("code", code), ("code_verifier", pkce.verifier), ("redirect_uri", Self.redirectURI),
            ], interactive: true)
            guard let refresh = reply.refresh_token else { throw DropboxAuthError.malformedResponse }
            let email = try await DropboxClient.currentAccountEmail(accessToken: reply.access_token, transport: transport)
            server.respond(success: true)
            return DropboxSignIn(accessToken: access(reply), refreshToken: refresh, email: email)
        } catch {
            server.respond(success: false)
            throw error
        }
    }

    /// `invalid_grant` means the refresh token is dead: `SourceError.accessRevoked`. Throws `SourceError` only.
    public func refresh(refreshToken: String) async throws -> DropboxAccessToken {
        access(try await tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refreshToken)], interactive: false))
    }

    // MARK: Internals

    private struct TokenReply: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
    }

    private func access(_ reply: TokenReply) -> DropboxAccessToken {
        DropboxAccessToken(token: reply.access_token, expiresAt: clock.now.addingTimeInterval(reply.expires_in ?? 14_400))
    }

    /// - Parameter interactive: a sign-in reports an unreadable answer as `DropboxAuthError`; a refresh, which
    ///   runs unattended, reports it as `SourceError.unavailable`.
    private func tokenRequest(_ fields: [(String, String)], interactive: Bool) async throws -> TokenReply {
        var request = URLRequest(url: DropboxEndpoint.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = Data(DropboxForm.encode(fields + [("client_id", appKey)]).utf8)
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request, body: .data(body)) } catch let error as URLError {
            throw error.code == .cancelled ? SourceError.cancelled : SourceError.unavailable
        }
        guard (200..<300).contains(response.statusCode) else {
            let tag = DropboxHTTP.errorTag(data)
            if tag == "invalid_grant" || tag == "invalid_client" { throw SourceError.accessRevoked }
            if response.statusCode == 429 || response.statusCode >= 500 { throw SourceError.busy }
            throw SourceError.unavailable
        }
        guard let reply = try? JSONDecoder().decode(TokenReply.self, from: data) else {
            throw interactive ? DropboxAuthError.malformedResponse : SourceError.unavailable
        }
        return reply
    }
}
