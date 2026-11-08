import Foundation
import PhotoVaultCore

/// Authorised request execution: adds the bearer token, refreshes once on 401, maps transport errors.
struct DriveHTTP: Sendable {
    let transport: any HTTPTransport
    let auth: any DriveAuthorizing

    /// Raw send: returns every HTTP status (the resumable protocol needs 308) except a 401 that
    /// survived one refresh, which throws `.unauthorized`.
    func send(_ url: URL, method: String, headers: [String: String] = [:], body: HTTPBody = .none) async throws -> (Data, HTTPURLResponse) {
        let token = try await auth.accessToken()
        let first = try await attempt(url, method, headers, body, token)
        guard first.1.statusCode == 401 else { return first }
        let refreshed = try await auth.refreshAfterUnauthorized(rejected: token)
        let second = try await attempt(url, method, headers, body, refreshed)
        if second.1.statusCode == 401 { throw DestinationError.unauthorized }
        return second
    }

    /// Like `send` but throws the mapped `DestinationError` for any non-success status.
    func sendChecked(_ url: URL, method: String, headers: [String: String] = [:], body: HTTPBody = .none) async throws -> Data {
        let (data, response) = try await send(url, method: method, headers: headers, body: body)
        if let error = DriveErrorMapper.error(data: data, response: response) { throw error }
        return data
    }

    func sendJSON<T: Decodable>(_ type: T.Type, _ url: URL, method: String, payload: (any Encodable)? = nil) async throws -> T {
        var headers: [String: String] = [:]
        var body = HTTPBody.none
        if let payload {
            headers["Content-Type"] = "application/json; charset=UTF-8"
            body = .data(try JSONEncoder().encode(AnyEncodable(payload)))
        }
        let data = try await sendChecked(url, method: method, headers: headers, body: body)
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw DestinationError.itemRejected(reason: "response malformed")
        }
    }

    private func attempt(_ url: URL, _ method: String, _ headers: [String: String], _ body: HTTPBody,
                         _ token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.send(request, body: body)
        } catch let error as URLError where error.code != .cancelled {
            throw DriveTransportError.map(error)
        }
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

enum DriveURL {
    static let api = "https://www.googleapis.com/drive/v3"
    static let upload = "https://www.googleapis.com/upload/drive/v3"

    static func make(_ base: String, _ path: String, _ query: [(String, String)] = []) -> URL {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.percentEncodedQuery = FormEncoding.encode(query) }
        return components.url!
    }

    /// Bearer tokens only go to Google API hosts over HTTPS (session URIs come from persisted state).
    static func isTrustedSession(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "googleapis.com" || host.hasSuffix(".googleapis.com")
    }
}
