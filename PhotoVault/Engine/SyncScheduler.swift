import Foundation
import PhotoVaultEngine

/// Timers of FR-14, FR-75 and spec 8.5: the 60 minute background activity, the 5 minute availability
/// re-check of offline folders, and the 15 minute re-check while the Mac disk is low.
@MainActor
final class SyncScheduler {
    private let hourly = NSBackgroundActivityScheduler(identifier: "com.annh.photovault.hourly-sync")
    private var recheck: Timer?
    private var diskRecheck: Timer?
    private let onTrigger: @MainActor (SyncTrigger) -> Void
    private let needsAvailabilityRecheck: @MainActor () -> Bool
    private let needsDiskRecheck: @MainActor () -> Bool

    init(onTrigger: @escaping @MainActor (SyncTrigger) -> Void, needsAvailabilityRecheck: @escaping @MainActor () -> Bool,
         needsDiskRecheck: @escaping @MainActor () -> Bool) {
        self.onTrigger = onTrigger
        self.needsAvailabilityRecheck = needsAvailabilityRecheck
        self.needsDiskRecheck = needsDiskRecheck
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
        recheck = repeating(every: 5 * 60) { [weak self] in self?.needsAvailabilityRecheck() ?? false }
        diskRecheck = repeating(every: 15 * 60) { [weak self] in self?.needsDiskRecheck() ?? false }
    }

    func stop() {
        hourly.invalidate()
        for timer in [recheck, diskRecheck] { timer?.invalidate() }
        recheck = nil
        diskRecheck = nil
    }

    private func repeating(every interval: TimeInterval, when condition: @escaping @MainActor () -> Bool) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, condition() else { return }
                self.onTrigger(.timer)
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
