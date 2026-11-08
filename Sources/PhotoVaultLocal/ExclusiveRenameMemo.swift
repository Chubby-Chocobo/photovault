import Darwin
import Foundation

/// Volumes (by `st_dev`) on which neither `RENAME_EXCL` nor `linkat` works (exFAT, some SMB servers).
/// Remembering them lets uploads go straight to the locked check-then-rename path instead of staging twice.
final class ExclusiveRenameMemo: @unchecked Sendable {
    /// Shared by all destinations of the process: the answer belongs to the volume.
    static let volumes = ExclusiveRenameMemo()

    private let lock = NSLock()
    private var devices: Set<dev_t> = []

    func isUnsupported(_ device: dev_t) -> Bool { lock.withLock { devices.contains(device) } }
    func markUnsupported(_ device: dev_t) { lock.withLock { _ = devices.insert(device) } }
}
