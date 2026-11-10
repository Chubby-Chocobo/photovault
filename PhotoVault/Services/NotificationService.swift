import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
@preconcurrency import UserNotifications

/// Posts the FR-61 notifications. Throttling happens before this point (`NotificationEvaluator`).
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    func configure() {
        center.delegate = self
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Shows the system prompt once; later calls return the stored answer.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func post(_ request: NotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        let identifier = "pv.\(request.kind.rawValue).\(request.destination?.rawValue ?? "-")"
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// A finished import. Not a condition that can repeat, so it is not throttled.
    func postImportFinished(id: SourceID, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: "pv.import.\(id.rawValue)", content: content, trigger: nil))
    }

    /// The end of a backfill. One identifier, so a repeat after a crash replaces the banner instead of stacking.
    func postBackfillFinished(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: "pv.backfill.finished", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A menu bar app is never "foreground" in the usual sense; show the banner anyway.
        completionHandler([.banner, .sound])
    }
}
