import Foundation
import IOKit.ps

/// AC / battery state through IOKit (FR-05, 8.5).
enum PowerSource {
    /// Desktop Macs report AC power; an unreadable state also counts as AC so uploads are not blocked by a read failure.
    static func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? else { return true }
        return type == kIOPSACPowerValue
    }
}

/// Calls `onChange` when the providing power source changes.
final class PowerSourceWatcher: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var source: CFRunLoopSource?

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            Unmanaged<PowerSourceWatcher>.fromOpaque(pointer).takeUnretainedValue().onChange()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        source = created
    }

    func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = nil
    }

    deinit { stop() }
}
