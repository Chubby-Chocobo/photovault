import Foundation

public struct LoopbackCallback: Equatable, Sendable {
    public var code: String?
    public var state: String?
    public var error: String?
    /// Comma-separated ids from Google's desktop Picker flow (`picked_file_ids`).
    public var pickedFileIds: String? = nil
}

public enum LoopbackError: Error, Equatable, Sendable {
    case malformedRequest
    case wrongPath
    case stateMismatch
    /// The authorization server returned `error=` (for example `access_denied`).
    case authorizationDenied(String)
    case missingCode
    case timeout
    case cancelled
    /// The redirect's request line is longer than the hard limit (a very large Picker selection).
    case requestTooLarge
}

/// Pure parsing of the single HTTP request the browser sends to the loopback redirect.
public enum LoopbackRequestParser {
    public static let callbackPath = "/oauth2/callback"
    /// Hard cap on the request line. The Picker redirect lists every picked id (about 35 bytes each), so this
    /// must hold the largest selection the app accepts; the listener is bound to loopback only.
    public static let maxRequestBytes = 256 * 1024
    /// How far a callback past the limit is read on while looking for its `state`; beyond this it is a stray request.
    static let strayRequestBytes = 4 * maxRequestBytes
    /// Bytes read from the socket at a time.
    static let readChunkBytes = 16 * 1024

    /// Parses the request line of a raw HTTP request.
    public static func parse(_ raw: String) throws -> LoopbackCallback {
        guard let line = raw.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            throw LoopbackError.malformedRequest
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"),
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            throw LoopbackError.malformedRequest
        }
        guard components.path == callbackPath else { throw LoopbackError.wrongPath }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return LoopbackCallback(code: value("code"), state: value("state"), error: value("error"), pickedFileIds: value("picked_file_ids"))
    }

    /// Checks the callback against the expected `state` (constant time) and extracts the code.
    public static func authorizationCode(from callback: LoopbackCallback, expectedState: String) throws -> String {
        guard let state = callback.state, constantTimeEquals(state, expectedState) else { throw LoopbackError.stateMismatch }
        if let error = callback.error { throw LoopbackError.authorizationDenied(error) }
        guard let code = callback.code, !code.isEmpty else { throw LoopbackError.missingCode }
        return code
    }

    /// True when the request text has a `state` query item equal to `expectedState` (checked in constant time).
    public static func carriesState(_ text: String, expectedState: String) -> Bool {
        guard let start = text.firstIndex(of: "?") else { return false }
        let line = text[start...].prefix { $0 != " " && $0 != "\r" }
        return line.dropFirst().split(separator: "&").contains { pair in
            pair.hasPrefix("state=") && constantTimeEquals(String(pair.dropFirst("state=".count)), expectedState)
        }
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}
