import Foundation
import PhotoVaultAppSupport
import PhotoVaultEngine

extension AppModel {
    /// Posts the one notification for a backfill that has ended, then tells the engine it is handled.
    /// When the system does not allow notifications the end is handled without posting, so it does not
    /// come back later if the owner turns them on.
    func noteBackfillCompletion(_ snapshot: EngineSnapshot) async {
        guard let env, !backfillNoticeInFlight, BackfillText.pendingNotification(snapshot) != nil else { return }
        backfillNoticeInFlight = true
        defer { backfillNoticeInFlight = false }
        // The stream and the poll can both hold a stale snapshot: decide on the engine's current flag.
        guard let done = BackfillText.pendingNotification(await env.coordinator.currentSnapshot()) else { return }
        if await notificationService.isAuthorized() {
            let text = BackfillText.notification(done)
            do {
                try await notificationService.postBackfillFinished(title: text.title, body: text.body)
                env.log.log(.info, category: "notification", "posted backfill finished")
            } catch {
                env.log.log(.error, category: "notification", "post failed: \(type(of: error))")
            }
        }
        do {
            try await env.coordinator.acknowledgeBackfillNotification()
        } catch {
            env.log.log(.error, category: "notification", "backfill acknowledgement failed: \(type(of: error))")
        }
    }
}
