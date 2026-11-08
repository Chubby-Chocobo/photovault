import Foundation
import PhotoVaultCore

/// At most one notification per kind and destination in any 12 hour window (FR-61). Persisted by
/// the caller so a relaunch does not repeat a notification.
public struct NotificationThrottle: Codable, Equatable, Sendable {
    public static let window: TimeInterval = 12 * 3600

    private var lastSent: [String: Date]

    public init() { lastSent = [:] }

    static func key(_ kind: NotificationKind, _ destination: DestinationID?) -> String {
        kind.rawValue + "|" + (destination?.rawValue ?? "-")
    }

    public func isAllowed(_ kind: NotificationKind, destination: DestinationID?, now: Date) -> Bool {
        guard let last = lastSent[Self.key(kind, destination)] else { return true }
        // A clock that moved backwards must not mute notifications for hours.
        return now < last || now.timeIntervalSince(last) >= Self.window
    }

    /// Records a send and returns true when it is allowed; returns false (and records nothing) when throttled.
    public mutating func admit(_ kind: NotificationKind, destination: DestinationID?, now: Date) -> Bool {
        guard isAllowed(kind, destination: destination, now: now) else { return false }
        lastSent[Self.key(kind, destination)] = now
        prune(now: now)
        return true
    }

    private mutating func prune(now: Date) {
        lastSent = lastSent.filter { now.timeIntervalSince($0.value) < Self.window * 2 }
    }
}

/// Decides which notifications are due (FR-61). Duration triggers compare persisted since-timestamps
/// with `now`, so they survive relaunches.
public enum NotificationEvaluator {
    public static let offlineThreshold: TimeInterval = 7 * 86400
    public static let longDurationThreshold: TimeInterval = 24 * 3600

    /// Conditions that hold right now, before throttling.
    public static func due(_ input: NotificationInputs, now: Date) -> [NotificationRequest] {
        guard input.onboardingComplete else { return [] }
        var requests: [NotificationRequest] = []
        func add(_ kind: NotificationKind, _ destination: NotificationInputs.Destination? = nil, count: Int? = nil) {
            let content = NotificationContent.make(kind, destinationName: destination?.name, count: count)
            requests.append(NotificationRequest(kind: kind, destination: destination?.id, title: content.title, body: content.body))
        }

        if input.photosAuthorization == .denied || input.photosAuthorization == .restricted {
            add(.photosPermissionLost)
        }
        for destination in input.destinations {
            let status = destination.status
            switch status.reason {
            case .reauthRequired: add(.reauthRequired, destination)
            case .full: add(.destinationFull, destination)
            case .rootMissing, .rootTrashed, .folderTrashed: add(.folderTrashedOrMissing, destination)
            case .bookmarkInvalid: add(.bookmarkInvalid, destination)
            case .offline:
                if destination.id.kind == .localFolder, case .unavailable = status,
                   now.timeIntervalSince(destination.statusSince) > offlineThreshold {
                    add(.destinationOfflineLong, destination)
                }
            default: break
            }
            if let missing = input.missingFiles[destination.id], missing > 0 { add(.integrityMissing, destination, count: missing) }
            if let bad = input.checksumMismatches[destination.id], bad > 0 { add(.checksumMismatch, destination, count: bad) }
        }
        if let since = input.macDiskFullSince, now.timeIntervalSince(since) > longDurationThreshold { add(.macDiskFullLong) }
        let anyActive = input.destinations.contains { $0.status.isActive }
        if input.photosAuthorization.allowsReading, !input.syncPausedByOwner, anyActive,
           let last = input.lastSuccessfulSyncAt, now.timeIntervalSince(last) > longDurationThreshold {
            add(.syncStalled)
        }
        return requests
    }

    /// `due` filtered through the throttle; admitted requests are recorded in `throttle`.
    public static func plan(_ input: NotificationInputs, throttle: inout NotificationThrottle, now: Date) -> [NotificationRequest] {
        due(input, now: now).filter { throttle.admit($0.kind, destination: $0.destination, now: now) }
    }
}
