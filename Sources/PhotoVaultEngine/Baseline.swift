import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// FR-15: the moment the owner presses Start. The token is taken first, then stored together with
/// the destination baselines; only then does the scan begin, so anything added during the scan is
/// replayed by the change history.
struct Baseline: Sendable {
    let env: EngineEnvironment

    var isTaken: Bool {
        (try? env.store.read { db in try KeyValueRepository.data(db, KeyValueRepository.Key.baselineToken) != nil }) ?? false
    }

    /// Takes the baseline once; calling it again is a no-op. Destinations without a baseline get `now`.
    @discardableResult
    func take(destinations: [DestinationID]) async throws -> ChangeToken {
        if let existing = try await env.store.read({ db in try KeyValueRepository.data(db, KeyValueRepository.Key.baselineToken) }) {
            return ChangeToken(data: existing)
        }
        let token = try await env.photos.currentChangeToken()
        let now = env.clock.now
        try await env.store.write { db in
            try KeyValueRepository.set(db, KeyValueRepository.Key.baselineToken, token.data)
            try KeyValueRepository.set(db, KeyValueRepository.Key.changeToken, token.data)
            try KeyValueRepository.setScanState(db, .notStarted)
            try KeyValueRepository.set(db, KeyValueRepository.Key.scanCursor, nil)
            for id in destinations {
                guard var record = try DestinationRepository.fetch(db, id: id) else { throw StoreError.notFound("destination \(id)") }
                record.baselineAt = now
                try DestinationRepository.save(db, record)
            }
        }
        env.log.log(.info, category: "baseline", "baseline taken for \(destinations.count) destination(s)")
        return token
    }
}
