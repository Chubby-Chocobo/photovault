import Foundation
import PhotoVaultEngine

/// Timers of FR-14 and FR-75: the 60 minute background activity and the 5 minute availability re-check.
@MainActor
final class SyncScheduler {
    private let hourly = NSBackgroundActivityScheduler(identifier: "com.annh.photovault.hourly-sync")
    private var recheck: Timer?
    private let onTrigger: @MainActor (SyncTrigger) -> Void
    private let needsAvailabilityRecheck: @MainActor () -> Bool

    init(onTrigger: @escaping @MainActor (SyncTrigger) -> Void, needsAvailabilityRecheck: @escaping @MainActor () -> Bool) {
        self.onTrigger = onTrigger
        self.needsAvailabilityRecheck = needsAvailabilityRecheck
    }

    func start() {
        hourly.repeats = true
        hourly.interval = 60 * 60
        hourly.tolerance = 5 * 60
        hourly.qualityOfService = .utility
        let trigger = onTrigger
        hourly.schedule { completion in
            Task { @MainActor in trigger(.timer) }
            completion(.finished)
        }
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.needsAvailabilityRecheck() else { return }
                self.onTrigger(.timer)
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        recheck = timer
    }

    func stop() {
        hourly.invalidate()
        recheck?.invalidate()
        recheck = nil
    }
}
