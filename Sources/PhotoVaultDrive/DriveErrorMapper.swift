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

    /// `Retry-After` as delta-seconds or an HTTP-date (RFC 9110); never negative.
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// nil for 2xx and 308 (resumable upload "incomplete").
    static func error(data: Data, response: HTTPURLResponse) -> DestinationError? {
        ErrorClassifier.destinationError(httpStatus: response.statusCode, reason: reason(data),
                                         retryAfter: retryAfter(response))
    }

    /// 403 for the reasons that mean "this scope/account may not do that" (shortcut operations, FR-103).
    /// Throttling 403s are `rateLimited` and any other reason stays an item error.
    static let forbiddenReasons: Set<String> = [
        "http 403 insufficientPermissions", "http 403 insufficientFilePermissions",
        "http 403 appNotAuthorizedToFile", "http 403 forbidden",
    ]

    static func isForbidden(_ error: DestinationError) -> Bool {
        if case .itemRejected(let reason) = error {
            return forbiddenReasons.contains(reason)
        }
        return false
    }
}
