import Foundation
import PhotoVaultCore

/// NFR-02: keeps the Mac from idle-sleeping while a cycle runs. Counted, so overlapping cycles share one assertion.
final class ActivityAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var depth = 0
    private var token: (any NSObjectProtocol)?

    func begin() {
        lock.withLock {
            depth += 1
            if depth == 1 {
                token = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "PhotoVault is syncing")
            }
        }
    }

    func end() {
        lock.withLock {
            guard depth > 0 else { return }
            depth -= 1
            if depth == 0, let token {
                ProcessInfo.processInfo.endActivity(token)
                self.token = nil
            }
        }
    }
}
