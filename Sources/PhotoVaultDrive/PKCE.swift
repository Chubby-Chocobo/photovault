import PhotoVaultCore
import CryptoKit
import Foundation
import Security

/// RFC 7636 PKCE (S256) plus the random `state` value.
public struct PKCE: Sendable {
    public let verifier: String
    public var challenge: String { Self.challenge(for: verifier) }

    /// 48 random bytes encode to a 64-character base64url verifier (within 43...128).
    public init() throws {
        verifier = Base64URL.encode(try Self.randomBytes(48))
    }

    public init(verifier: String) { self.verifier = verifier }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomState() throws -> String { Base64URL.encode(try randomBytes(32)) }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw DestinationError.transient(reason: "random bytes unavailable")
        }
        return Data(bytes)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

