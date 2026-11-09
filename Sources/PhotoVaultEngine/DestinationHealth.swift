import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Step 1 of the cycle for each destination: ask it for its availability and record the status.
/// States that wait for the owner (`paused(userPaused)`, `paused(recovering)`, `paused(folderTrashed)`,
/// `paused(signedOut)`) are never overridden: the destination would only hit the same trashed folder
/// again, or upload with a token the owner has not confirmed. Signing in again clears `signedOut`.
struct DestinationHealth: Sendable {
    let env: EngineEnvironment

    func refresh() async throws {
        let records = try await env.store.read { db in try DestinationRepository.fetchAll(db) }
        for record in records {
            if [.paused(.userPaused), .paused(.recovering), .paused(.folderTrashed), .paused(.signedOut)].contains(record.status) {
                continue
            }
            guard let destination = await env.destinations.destination(for: record.id) else { continue }
            let status = await destination.checkAvailability()
            guard status != record.status else { continue }
            let id = record.id
            let now = env.clock.now
            try await env.store.write { db in try DestinationRepository.setStatus(db, id: id, status: status, now: now) }
            env.log.log(.notice, category: "destination", "destination \(id) status \(record.status) -> \(status)")
        }
    }
}
