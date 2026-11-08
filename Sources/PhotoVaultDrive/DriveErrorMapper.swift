import Foundation
import PhotoVaultCore

enum DriveTransportError {
    /// Network-level failures. Connectivity problems are `offline`; everything else is retryable.
    static func map(_ error: URLError) -> DestinationError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            .offline
        default:
            .transient(reason: "network \(error.code.rawValue)")
        }
    }
}

enum DriveErrorMapper {
    private struct Body: Decodable {
        struct Inner: Decodable {
            struct Item: Decodable { var reason: String? }
            var errors: [Item]?
            var status: String?
        }
        var error: Inner?
    }

    /// `error.errors[0].reason` of a Google API error body.
    static func reason(_ data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        return body.error?.errors?.first?.reason ?? body.error?.status
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
    }

    /// nil for 2xx and 308 (resumable upload "incomplete").
    static func error(data: Data, response: HTTPURLResponse) -> DestinationError? {
        ErrorClassifier.destinationError(httpStatus: response.statusCode, reason: reason(data),
                                         retryAfter: retryAfter(response))
    }

    /// 403 for reasons that mean "this scope/account may not do that" (shortcut operations, FR-103).
    static func isForbidden(_ error: DestinationError) -> Bool {
        if case .itemRejected(let reason) = error { return reason.hasPrefix("http 403") }
        return false
    }
}
