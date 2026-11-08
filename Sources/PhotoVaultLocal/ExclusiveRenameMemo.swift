import Darwin
import Foundation

/// A mounted filesystem: its device number plus the volume UUID (or, lacking one, the mount source).
/// A device number alone can be reused by another volume after a remount.
struct VolumeKey: Hashable, Sendable {
    let device: dev_t
    let identity: String

    init(device: dev_t, identity: String) {
        self.device = device
        self.identity = identity
    }

    /// The key of the volume an open descriptor lives on.
    init(fd: Int32, device: dev_t) {
        self.device = device
        self.identity = Self.volumeUUID(fd: fd) ?? Self.mountSource(fd: fd) ?? ""
    }

    private struct UUIDReply {
        var length: UInt32 = 0
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static func volumeUUID(fd: Int32) -> String? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
        var reply = UUIDReply()
        let status = withUnsafeMutableBytes(of: &reply) { fgetattrlist(fd, &list, $0.baseAddress, $0.count, 0) }
        guard status == 0 else { return nil }
        return UUID(uuid: reply.uuid).uuidString
    }

    private static func mountSource(fd: Int32) -> String? {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return nil }
        return withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}

/// Volumes on which neither `RENAME_EXCL` nor `linkat` works (exFAT, some SMB servers).
/// Remembering them lets uploads go straight to the locked check-then-rename path instead of staging twice.
/// Keyed by device and volume UUID, so a device number reused by another volume inherits nothing.
final class ExclusiveRenameMemo: @unchecked Sendable {
    /// Shared by all destinations of the process: the answer belongs to the volume.
    static let volumes = ExclusiveRenameMemo()

    private let lock = NSLock()
    private var unsupported: Set<VolumeKey> = []

    func isUnsupported(_ volume: VolumeKey) -> Bool { lock.withLock { unsupported.contains(volume) } }
    func markUnsupported(_ volume: VolumeKey) { lock.withLock { _ = unsupported.insert(volume) } }
}
