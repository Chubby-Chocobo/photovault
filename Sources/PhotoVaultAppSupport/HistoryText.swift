import Foundation
import PhotoVaultCore

/// Labels of the History window. File names are shown there only; nothing here reaches a log.
public enum HistoryText {
    public static func outcome(_ outcome: TransferOutcome) -> String {
        switch outcome {
        case .uploaded: tr(vi: "Đã lên", en: "Uploaded")
        case .updated: tr(vi: "Đã cập nhật", en: "Updated")
        case .failed: tr(vi: "Lỗi", en: "Failed")
        case .skipped: tr(vi: "Bỏ qua", en: "Skipped")
        case .cancelled: tr(vi: "Đã huỷ", en: "Cancelled")
        }
    }

    /// Why the file was sent.
    public static func origin(_ origin: JobOrigin) -> String {
        switch origin {
        case .incremental: tr(vi: "Ảnh mới", en: "New photo")
        case .refresh: tr(vi: "Bản sửa", en: "Edit")
        case .reupload: tr(vi: "Upload lại", en: "Re-upload")
        case .backfill: tr(vi: "Backfill", en: "Backfill")
        case .destinationBackfill: tr(vi: "Đích mới", en: "New destination")
        }
    }

    public static func trigger(_ trigger: BackfillTrigger) -> String {
        switch trigger {
        case .library: tr(vi: "Backfill thư viện", en: "Library backfill")
        case .settings: tr(vi: "Mở rộng phạm vi", en: "Wider scope")
        case .destinationAdded: tr(vi: "Thêm đích", en: "Destination added")
        case .recovery: tr(vi: "Sau khi khôi phục từ đích", en: "After recovery from the destination")
        case .beforeHistory: tr(vi: "Trước khi có lịch sử", en: "Before history began")
        }
    }

    public static func importState(_ state: ImportItemState) -> String {
        switch state {
        case .pending: tr(vi: "Đang chờ", en: "Waiting")
        case .imported: tr(vi: "Đã nhập", en: "Imported")
        case .duplicate: tr(vi: "Đã có sẵn", en: "Already backed up")
        case .unsupported: tr(vi: "Không hỗ trợ", en: "Not supported")
        case .failed: tr(vi: "Lỗi", en: "Failed")
        case .cancelled: tr(vi: "Đã huỷ", en: "Cancelled")
        }
    }

    public static func media(_ media: HistoryMediaFilter) -> String {
        switch media {
        case .all: tr(vi: "Mọi loại", en: "All types")
        case .photo: tr(vi: "Ảnh", en: "Photos")
        case .video: tr(vi: "Video", en: "Videos")
        case .raw: "RAW"
        }
    }

    /// Where a file stands at a destination now.
    public static func state(_ state: JobState) -> String {
        switch state {
        case .done: tr(vi: "Đã lên", en: "Backed up")
        case .pending: tr(vi: "Đang chờ", en: "Waiting")
        case .uploading: tr(vi: "Đang upload", en: "Uploading")
        case .deferred: tr(vi: "Lỗi, sẽ thử lại", en: "Failed, will retry")
        case .skipped: tr(vi: "Bỏ qua", en: "Skipped")
        case .cancelled: tr(vi: "Không upload", en: "Not uploaded")
        case .missingRemote: tr(vi: "Không còn ở đích", en: "Missing at the destination")
        }
    }

    /// "Đã lên · kiểm tra 10/11/2026 09:00: còn nguyên (đã kiểm checksum)", with the reason of a failure.
    public static func status(_ status: FileDestinationStatus, calendar: Calendar = .current) -> String {
        var parts = [state(status.state)]
        if status.state == .deferred || status.state == .skipped, let reason = HistoryReasonText.upload(reason: status.reason, detail: status.detail) {
            parts.append(reason)
        }
        if let result = status.checkResult, let at = status.checkedAt {
            parts.append(check(result, at: at, calendar: calendar))
        }
        return parts.joined(separator: " · ")
    }

    public static func check(_ result: IntegrityCheckResult, at date: Date, calendar: Calendar = .current) -> String {
        let when = RelativeTimeText.dateTime(date, calendar: calendar)
        let what = switch result {
        // Without a re-hash a check only sees that the file is there (and, on a folder, its size): it does not
        // vouch for the content.
        case .intact: tr(vi: "vẫn còn ở đích", en: "still at the destination")
        case .hashVerified: tr(vi: "còn nguyên (đã kiểm checksum)", en: "intact (checksum verified)")
        case .missing: tr(vi: "không thấy ở đích", en: "not found at the destination")
        case .sizeMismatch: tr(vi: "sai dung lượng", en: "wrong size")
        case .hashMismatch: tr(vi: "checksum không khớp", en: "checksum mismatch")
        }
        return tr(vi: "kiểm tra \(when): \(what)", en: "checked \(when): \(what)")
    }

    /// The name of a destination, or a placeholder once it was removed.
    public static func destination(_ id: DestinationID, names: [DestinationID: String]) -> String {
        names[id] ?? tr(vi: "Đích đã xoá", en: "Removed destination")
    }

    /// "≈" before the time of a row copied from the time before history began.
    public static func time(_ date: Date, approximate: Bool, calendar: Calendar = .current) -> String {
        (approximate ? "≈ " : "") + RelativeTimeText.dateTime(date, calendar: calendar)
    }

    /// A read of the history failed (the error type is in the log).
    public static var readFailed: String {
        tr(vi: "Không đọc được lịch sử. Bấm Làm mới để thử lại.", en: "The history could not be read. Click Refresh to try again.")
    }

    public static var approximateNote: String {
        tr(vi: "≈ gần đúng: file đã lên trước khi PhotoVault ghi lịch sử, thời điểm là lần thay đổi cuối của nó",
           en: "≈ approximate: the file was uploaded before PhotoVault kept a history; the time is its last change")
    }

    public static var deletedFromLibrary: String {
        tr(vi: "Đã xoá khỏi Photos, bản backup vẫn giữ", en: "Deleted from Photos; the backup is kept")
    }

    /// Whether a row is an upload of a photo later deleted from Photos, whose copy is kept: only those get the
    /// "backup is kept" mark. A photo deleted before it went up has no backup to speak of.
    public static func keptAfterDeletion(_ row: TransferEventRow) -> Bool {
        row.deletedFromLibraryAt != nil && (row.outcome == .uploaded || row.outcome == .updated)
    }

    /// The note of a row whose photo was deleted from Photos, or nil.
    public static func deletionNote(_ row: TransferEventRow) -> String? {
        guard row.deletedFromLibraryAt != nil else { return nil }
        return keptAfterDeletion(row) ? deletedFromLibrary : tr(vi: "Đã xoá khỏi Photos", en: "Deleted from Photos")
    }
}
