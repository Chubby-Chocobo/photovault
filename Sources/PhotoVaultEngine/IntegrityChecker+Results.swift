import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

extension IntegrityChecker {
    static let resultBatch = 500

    /// The latest result of each file the check found in order, for the history. Written in batches so a check of
    /// a large library never holds the database for long; a file the check marked missing was written with its mark.
    func recordChecked(_ results: [(JobIdentity, IntegrityCheckResult)]) async throws {
        let now = env.clock.now
        for start in stride(from: 0, to: results.count, by: Self.resultBatch) {
            let batch = Array(results[start..<min(start + Self.resultBatch, results.count)])
            try await env.store.write { db in
                for (identity, result) in batch where !identity.resType.isSidecar {
                    try IntegrityCheckRepository.record(db, identity: identity, result: result, at: now)
                }
            }
        }
    }
}
