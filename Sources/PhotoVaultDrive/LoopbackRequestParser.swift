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
}

/// Pure parsing of the single HTTP request the browser sends to the loopback redirect.
public enum LoopbackRequestParser {
    public static let callbackPath = "/oauth2/callback"
    public static let maxRequestBytes = 8192

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

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}
