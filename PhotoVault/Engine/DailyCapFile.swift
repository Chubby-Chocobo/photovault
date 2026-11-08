import Foundation
import os
import PhotoVaultDrive

/// Persists the Drive 24-hour upload cap (FR-49) across launches. Changes arrive synchronously from
/// the Drive actor, so they are coalesced and written on a background queue, newest state last.
final class DailyCapFile: Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "photovault.daily-cap", qos: .utility)
    private let pending = OSAllocatedUnfairLock<DailyCapState?>(initialState: nil)

    init(url: URL) { self.url = url }

    func load() -> DailyCapState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DailyCapState.self, from: data)
    }

    /// Called on every reserve/release: records the newest state and schedules one write.
    func record(_ state: DailyCapState) {
        let scheduleWrite = pending.withLock { current -> Bool in
            defer { current = state }
            return current == nil
        }
        guard scheduleWrite else { return }
        queue.async { [self] in writePending() }
    }

    /// Writes the newest recorded state now and returns once it is on disk. For application termination,
    /// when a queued write might never run.
    func flush() {
        queue.sync { writePending() }
    }

    private func writePending() {
        guard let latest = pending.withLock({ current -> DailyCapState? in
            defer { current = nil }
            return current
        }) else { return }
        guard let data = try? JSONEncoder().encode(latest) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
