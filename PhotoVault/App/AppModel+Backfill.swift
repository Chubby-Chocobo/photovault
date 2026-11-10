import Foundation
import PhotoVaultAppSupport
import PhotoVaultEngine

extension AppModel {
    /// Posts the one notification for a backfill that has ended, then tells the engine it is handled.
    /// When the system does not allow notifications the end is handled without posting, so it does not
    /// come back later if the owner turns them on.
    func noteBackfillCompletion(_ snapshot: EngineSnapshot) async {
        guard let env, !backfillNoticeInFlight, let done = BackfillText.pendingNotification(snapshot) else { return }
        backfillNoticeInFlight = true
        defer { backfillNoticeInFlight = false }
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
