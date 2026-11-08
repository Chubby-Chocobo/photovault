import AppKit
import Foundation
import PhotoVaultEngine

/// Wake, sleep and volume mount events (FR-14, FR-75).
final class WorkspaceMonitor: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol] = []
    private let onTrigger: @Sendable (SyncTrigger) -> Void

    init(onTrigger: @escaping @Sendable (SyncTrigger) -> Void) { self.onTrigger = onTrigger }

    func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let trigger = onTrigger
        for (name, mapped) in [
            (NSWorkspace.didWakeNotification, SyncTrigger.wake),
            (NSWorkspace.didMountNotification, .volumeMounted),
            (NSWorkspace.didUnmountNotification, .volumeMounted),
        ] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in trigger(mapped) })
        }
    }

    func stop() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens.removeAll()
    }
}
