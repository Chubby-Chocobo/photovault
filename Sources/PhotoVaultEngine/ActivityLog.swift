import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// FR-63: owner-visible events (newest 500 kept). Messages never carry file names, coordinates,
/// tokens or session URIs (NFR-06).
struct ActivityLog: Sendable {
    let env: EngineEnvironment

    func record(_ kind: ActivityKind, destination: DestinationID? = nil, asset: AssetKey? = nil, _ message: String) async {
        let event = ActivityEvent(at: env.clock.now, kind: kind, destinationId: destination, assetKey: asset, message: message)
        do {
            try await env.store.write { db in try ActivityRepository.record(db, event) }
        } catch {
            env.log.log(.error, category: "activity", "could not record activity event")
        }
    }

    /// Records a destination status change when the status actually differs.
    func statusChanged(_ id: DestinationID, to status: DestinationStatus) async {
        await record(.statusChanged, destination: id, "status \(status)")
    }
}
