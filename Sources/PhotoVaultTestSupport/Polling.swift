import Foundation

/// Polls `condition` until it holds and returns true, or returns false once `timeout` has passed.
/// The timeout only turns a hang into a failure: a loaded machine makes the wait longer, never the result different.
public func pollUntil(timeout: Duration = .seconds(60), _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, !Task.isCancelled {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return try await condition()
}
