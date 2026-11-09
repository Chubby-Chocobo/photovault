import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// FR-63: owner-visible events (newest 500 kept). Messages never carry file names, coordinates,
/// tokens or session URIs (NFR-06). Status changes are recorded by `DestinationRepository.setStatus`.
struct ActivityLog: Sendable {
    let env: EngineEnvironment

    func record(_ kind: ActivityKind, destination: DestinationID? = nil, asset: AssetKey? = nil, _ message: String) async {
        await record([(kind, message)], destination: destination, asset: asset)
    }

    /// Records several rows in one transaction, in order.
    func record(_ rows: [(kind: ActivityKind, message: String)], destination: DestinationID?, asset: AssetKey? = nil) async {
        guard !rows.isEmpty else { return }
        let env = env
        // In its own task, so a row about work that did happen is kept when the caller is cancelled.
        await Task {
            let now = env.clock.now
            do {
                try await env.store.write { db in
                    for row in rows {
                        try ActivityRepository.record(db, ActivityEvent(
                            at: now, kind: row.kind, destinationId: destination, assetKey: asset, message: row.message))
                    }
                }
            } catch {
                env.log.log(.error, category: "activity", "could not record activity event")
            }
        }.value
    }
}
