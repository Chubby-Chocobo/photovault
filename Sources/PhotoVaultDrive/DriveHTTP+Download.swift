import Foundation
import PhotoVaultCore

extension DriveHTTP {
    /// Streams a GET into `sink`. A 401 is retried once with a refreshed token before any byte reaches the
    /// sink. Returns the mapped error for a non-2xx answer; errors thrown by the sink propagate unchanged.
    func download(_ url: URL, sink: @Sendable (Data) throws -> Void) async throws {
        let token = try await auth.accessToken()
        var result = try await attemptStream(url, token, sink)
        if result.1.statusCode == 401 {
            let refreshed = try await auth.refreshAfterUnauthorized(rejected: token)
            result = try await attemptStream(url, refreshed, sink)
            if result.1.statusCode == 401 { throw DestinationError.unauthorized }
        }
        if let error = DriveErrorMapper.error(data: result.0, response: result.1) { throw error }
    }

    private func attemptStream(_ url: URL, _ token: String, _ sink: @Sendable (Data) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await transport.streamBody(request, sink: sink)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw DriveTransportError.map(error)
        }
    }
}
