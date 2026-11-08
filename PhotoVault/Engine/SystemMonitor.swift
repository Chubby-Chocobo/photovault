import Foundation
import Network
import PhotoVaultCore
import PhotoVaultEngine

/// Network, power, Low Power Mode and thermal state for the engine (FR-05, 8.5, NFR-05). Changes that
/// matter for syncing are reported as triggers.
final class SystemMonitor: SystemConditions, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SystemSnapshot
    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.annh.photovault.system-monitor")
    private var power: PowerSourceWatcher?
    private var observers: [any NSObjectProtocol] = []
    private var onTrigger: (@Sendable (SyncTrigger) -> Void)?

    init() {
        current = SystemSnapshot(
            onACPower: PowerSource.isOnACPower(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: Self.level(ProcessInfo.processInfo.thermalState), networkAvailable: true)
    }

    func snapshot() async -> SystemSnapshot { lock.withLock { current } }

    func start(onTrigger: @escaping @Sendable (SyncTrigger) -> Void) {
        self.onTrigger = onTrigger
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.update { snapshot in
                let wasOffline = !snapshot.networkAvailable
                snapshot.networkAvailable = path.status == .satisfied
                snapshot.networkExpensive = path.isExpensive
                snapshot.networkConstrained = path.isConstrained
                return wasOffline && snapshot.networkAvailable ? .networkBack : nil
            }
        }
        pathMonitor.start(queue: queue)

        let watcher = PowerSourceWatcher { [weak self] in
            self?.update { snapshot in
                let wasOnBattery = !snapshot.onACPower
                snapshot.onACPower = PowerSource.isOnACPower()
                return wasOnBattery && snapshot.onACPower ? .timer : nil
            }
        }
        watcher.start()
        power = watcher

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.update { snapshot in
                let was = snapshot.lowPowerMode
                snapshot.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                return was && !snapshot.lowPowerMode ? .timer : nil
            }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.update { snapshot in
                let was = snapshot.thermal
                snapshot.thermal = Self.level(ProcessInfo.processInfo.thermalState)
                return was >= .serious && snapshot.thermal < .serious ? .timer : nil
            }
        })
    }

    func stop() {
        pathMonitor.cancel()
        power?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func update(_ change: (inout SystemSnapshot) -> SyncTrigger?) {
        // Read-modify-write under one lock: the path monitor and the main thread both report changes.
        let trigger = lock.withLock { change(&current) }
        if let trigger { onTrigger?(trigger) }
    }

    static func level(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}
