import Foundation
import PhotoVaultCore

/// The FR-61 notification list. Each kind is sent at most once per 12 hours per destination.
public enum NotificationKind: String, CaseIterable, Codable, Sendable {
    case photosPermissionLost
    case reauthRequired
    case destinationFull
    case folderTrashedOrMissing
    case integrityMissing
    case checksumMismatch
    case destinationOfflineLong
    case bookmarkInvalid
    case macDiskFullLong
    case syncStalled

    /// Kinds that describe the Mac or the app rather than one destination.
    public var isGlobal: Bool {
        switch self {
        case .photosPermissionLost, .macDiskFullLong, .syncStalled: true
        default: false
        }
    }

    /// One line per kind, as the onboarding step lists them.
    public var summary: String {
        switch self {
        case .photosPermissionLost: tr(vi: "Mất quyền Photos", en: "Photos access lost")
        case .reauthRequired: tr(vi: "Cần đăng nhập Google lại", en: "Google sign-in required")
        case .destinationFull: tr(vi: "Đích sắp đầy hoặc đã đầy", en: "Destination full or almost full")
        case .folderTrashedOrMissing: tr(vi: "Thư mục backup bị xoá hoặc vào Thùng rác", en: "Backup folder deleted or moved to Trash")
        case .integrityMissing: tr(vi: "Kiểm tra toàn vẹn thấy thiếu file", en: "Integrity check found missing files")
        case .checksumMismatch: tr(vi: "Checksum lệch", en: "Checksum mismatch")
        case .destinationOfflineLong: tr(vi: "NAS offline quá 7 ngày", en: "NAS offline for over 7 days")
        case .bookmarkInvalid: tr(vi: "Mất quyền truy cập thư mục (bookmark hỏng)", en: "Lost access to the folder (broken bookmark)")
        case .macDiskFullLong: tr(vi: "Ổ Mac đầy quá 24 giờ", en: "Mac disk full for over 24 hours")
        case .syncStalled: tr(vi: "Không sync được quá 24 giờ", en: "Sync not working for over 24 hours")
        }
    }
}

public struct NotificationRequest: Equatable, Sendable {
    public var kind: NotificationKind
    public var destination: DestinationID?
    public var title: String
    public var body: String
}

/// Everything the evaluator needs, read from the database and the system by the app.
public struct NotificationInputs: Sendable {
    public struct Destination: Sendable, Equatable {
        public var id: DestinationID
        public var name: String
        public var status: DestinationStatus
        /// `destination.status_since`: when the current status began.
        public var statusSince: Date

        public init(id: DestinationID, name: String, status: DestinationStatus, statusSince: Date) {
            self.id = id
            self.name = name
            self.status = status
            self.statusSince = statusSince
        }
    }

    public var onboardingComplete: Bool
    public var photosAuthorization: PhotosAuthorization
    public var syncPausedByOwner: Bool
    public var destinations: [Destination]
    /// `kv.mac_disk_full_since`.
    public var macDiskFullSince: Date?
    /// `kv.last_successful_sync_at`.
    public var lastSuccessfulSyncAt: Date?
    public var missingFiles: [DestinationID: Int]
    public var checksumMismatches: [DestinationID: Int]

    public init(
        onboardingComplete: Bool, photosAuthorization: PhotosAuthorization, syncPausedByOwner: Bool = false,
        destinations: [Destination], macDiskFullSince: Date? = nil, lastSuccessfulSyncAt: Date? = nil,
        missingFiles: [DestinationID: Int] = [:], checksumMismatches: [DestinationID: Int] = [:]
    ) {
        self.onboardingComplete = onboardingComplete
        self.photosAuthorization = photosAuthorization
        self.syncPausedByOwner = syncPausedByOwner
        self.destinations = destinations
        self.macDiskFullSince = macDiskFullSince
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.missingFiles = missingFiles
        self.checksumMismatches = checksumMismatches
    }
}
