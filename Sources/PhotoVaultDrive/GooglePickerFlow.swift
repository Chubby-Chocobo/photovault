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
}

/// Google's desktop Picker flow: OAuth with `drive.file` (so the Picker's grants work) plus `drive.readonly`
/// (so the folders picked can be read to their depth) and `trigger_onepick`. Only imports use it; the backup destination stays `drive.file`. The browser
/// shows the account chooser, consent and the picker; the loopback redirect carries `picked_file_ids`.
public struct GooglePickerFlow: Sendable {
    static let readScope = "https://www.googleapis.com/auth/drive.readonly"
    public static let scope = "https://www.googleapis.com/auth/drive.file " + readScope
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

    public init(config: OAuthConfig, transport: any HTTPTransport, clock: any Clock = SystemClock(),
                openURL: @escaping URLOpening, loopbackTimeout: TimeInterval = GooglePickerFlow.pickTimeout) {
        self.config = config
        self.transport = transport
        self.clock = clock
        self.openURL = openURL
        self.loopbackTimeout = loopbackTimeout
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
        var components = URLComponents(url: OAuthConfig.authEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = FormEncoding.encode(fields)
        return components.url!
    }

    /// Interactive; call only from an explicit user action. Network and token failures are `DestinationError`.
    public func run() async throws -> PickerResult {
        let pkce = try PKCE()
        let state = try PKCE.randomState()
        let server = try LoopbackRedirectServer(expectedState: state, timeout: loopbackTimeout)
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)\(LoopbackRequestParser.callbackPath)"
        let url = Self.authorizationURL(clientID: config.clientID, redirectURI: redirectURI, state: state, challenge: pkce.challenge)
        guard await openURL(url) else {
            server.cancel()
            throw PickerError.browserUnavailable
        }
        let code: String
        do { code = try await server.awaitCode() } catch let error as LoopbackError {
            switch error {
            case .timeout: throw PickerError.timedOut
            case .cancelled, .authorizationDenied("access_denied"): throw PickerError.cancelled
            case .requestTooLarge: throw PickerError.selectionTooLarge
            default: throw DestinationError.itemRejected(reason: "picker redirect \(error)")
            }
        }
        do {
            let ids = try Self.parseIds(server.receivedCallback?.pickedFileIds)
            guard !ids.isEmpty else { throw PickerError.nothingPicked }
            let oauth = OAuthClient(config: config, transport: transport, clock: clock, openURL: openURL)
            let tokens: OAuthTokens
            do {
                tokens = try await oauth.exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
            } catch DestinationError.itemRejected(let reason) where reason == OAuthClient.fileScopeMissing {
                throw PickerError.pickAccessDenied
            }
            // Google shows the two Drive permissions as separate boxes; without this one a picked folder lists as empty.
            guard tokens.scopes.contains(Self.readScope) else { throw PickerError.readAccessDenied }
            guard let refresh = tokens.refreshToken else { throw PickerError.tokenMissing }
            let email = await Self.email(transport: transport, accessToken: tokens.accessToken)
            server.respond(success: true)
            return PickerResult(pickedIds: ids, refreshToken: refresh, accessToken: tokens.accessToken,
                                expiresAt: tokens.expiresAt, email: email)
        } catch {
            if let picker = error as? PickerError, picker == .selectionTooLarge { server.respondSelectionTooLarge() } else { server.respond(success: false) }
            throw error
        }
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

    private static func email(transport: any HTTPTransport, accessToken: String) async -> String? {
        struct About: Decodable { struct User: Decodable { var emailAddress: String? }; var user: User? }
        let http = DriveHTTP(transport: transport, auth: FixedTokenAuth(token: accessToken))
        let url = DriveURL.make(DriveURL.api, "/about", [("fields", "user(emailAddress)")])
        return try? await http.sendJSON(About.self, url, method: "GET").user?.emailAddress
    }
}

/// A token that is used as is; a 401 cannot be refreshed.
struct FixedTokenAuth: DriveAuthorizing {
    let token: String
    func accessToken() async throws -> String { token }
    func refreshAfterUnauthorized(rejected: String) async throws -> String { throw DestinationError.reauthRequired }
}
