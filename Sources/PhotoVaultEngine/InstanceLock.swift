import Darwin
import Foundation

/// FR-54: one engine per container. An exclusive, non-blocking `flock` on `photovault.lock`; the
/// kernel drops it when the process dies, so a crash never leaves a stale lock.
public final class InstanceLock: @unchecked Sendable {
    public enum LockError: Error, Equatable {
        case alreadyRunning
        case cannotOpen(errno: Int32)
    }

    public static let fileName = "photovault.lock"

    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(containerDirectory: URL) throws -> InstanceLock {
        try FileManager.default.createDirectory(at: containerDirectory, withIntermediateDirectories: true)
        let path = containerDirectory.appendingPathComponent(fileName).path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LockError.cannotOpen(errno: errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw LockError.alreadyRunning }
            throw LockError.cannotOpen(errno: code)
        }
        return InstanceLock(descriptor: fd)
    }

    /// Releases the lock; also done on deinit.
    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
