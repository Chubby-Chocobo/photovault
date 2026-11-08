import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Step 1 of the cycle for each destination: ask it for its availability and record the status.
/// Owner-controlled states (`paused(userPaused)`, `paused(recovering)`) are never overridden.
struct DestinationHealth: Sendable {
    let env: EngineEnvironment

    func refresh() async throws {
        let records = try await env.store.read { db in try DestinationRepository.fetchAll(db) }
        for record in records {
            if record.status == .paused(.userPaused) || record.status == .paused(.recovering) { continue }
            guard let destination = await env.destinations.destination(for: record.id) else { continue }
            let status = await destination.checkAvailability()
            guard status != record.status else { continue }
            let id = record.id
            let now = env.clock.now
            try await env.store.write { db in try DestinationRepository.setStatus(db, id: id, status: status, now: now) }
            await ActivityLog(env: env).statusChanged(id, to: status)
            env.log.log(.notice, category: "destination", "destination \(id) status \(record.status) -> \(status)")
        }
    }
}
