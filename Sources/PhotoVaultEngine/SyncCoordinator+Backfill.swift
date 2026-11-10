import Foundation
import PhotoVaultStore

extension SyncCoordinator {
    /// The app has posted (or chosen not to post) the notification for the last backfill's end.
    public func acknowledgeBackfillNotification() async throws {
        try await env.store.write { db in try BackfillCompletion.acknowledgeNotification(db) }
        await publish()
    }

    /// Once per launch, before the cycle changes anything: a backfill already finished by an older
    /// version is marked as completed without announcing it.
    func markEarlierBackfillOnce() async throws {
        guard !earlierBackfillMarked else { return }
        let settings = await env.settingsSnapshot()
        try await env.store.write { db in try BackfillCompletion.markEarlierBackfill(db, settings: settings) }
        earlierBackfillMarked = true
    }
}
