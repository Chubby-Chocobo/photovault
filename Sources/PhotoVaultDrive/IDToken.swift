import PhotoVaultCore
import Foundation

/// The Google account behind a sign-in (FR-08 account change detection uses `sub`).
public struct GoogleIdentity: Equatable, Sendable {
    public var sub: String
    public var email: String?
}

enum IDToken {
    private static let issuers: Set<String> = ["accounts.google.com", "https://accounts.google.com"]

    private struct Claims: Decodable {
        var iss: String?
        var aud: Audience?
        var exp: Double?
        var sub: String?
        var email: String?
    }

    private enum Audience: Decodable {
        case one(String), many([String])
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) }
        }
        func contains(_ value: String) -> Bool {
            switch self {
            case .one(let s): s == value
            case .many(let a): a.contains(value)
            }
        }
    }

    /// Decodes the payload and checks `aud`, `iss` and `exp`. The signature is not verified: the
    /// token was received directly from Google's token endpoint over TLS in the same exchange
    /// (OpenID Connect Core 3.1.3.7 permits this), so TLS authenticates the issuer.
    static func identity(from jwt: String, clientID: String, now: Date) throws -> GoogleIdentity {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Base64URL.decode(String(parts[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload) else {
            throw DestinationError.itemRejected(reason: "id token malformed")
        }
        guard claims.aud?.contains(clientID) == true else { throw DestinationError.itemRejected(reason: "id token audience") }
        guard let iss = claims.iss, issuers.contains(iss) else { throw DestinationError.itemRejected(reason: "id token issuer") }
        guard let exp = claims.exp, Date(timeIntervalSince1970: exp) > now else { throw DestinationError.itemRejected(reason: "id token expired") }
        guard let sub = claims.sub, !sub.isEmpty else { throw DestinationError.itemRejected(reason: "id token subject") }
        return GoogleIdentity(sub: sub, email: claims.email)
    }
}
