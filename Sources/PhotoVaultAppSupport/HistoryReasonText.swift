import Foundation
import PhotoVaultCore

/// Why a file did not go up, in words the owner understands. Built from machine reasons only (a job's state
/// reason, the case name of its last error, an import item's reason), never from a path.
public enum HistoryReasonText {
    /// An upload that failed or was skipped: the reason, then what the destination said when it adds something.
    public static func upload(reason: JobStateReason?, detail: String?) -> String? {
        let main = reason.map(text)
        let extra = detail.flatMap(error)
        switch (main, extra) {
        case let (main?, extra?) where reason == .uploadFailures || reason == .permanentError: return main + ": " + extra
        case let (main?, _): return main
        case let (nil, extra?): return extra
        default: return nil
        }
    }

    static func text(_ reason: JobStateReason) -> String {
        switch reason {
        case .uploadFailures: tr(vi: "Upload lỗi nhiều lần liền, sẽ tự thử lại sau 24 giờ", en: "The upload failed several times in a row; it is tried again after 24 hours")
        case .exportFailures: tr(vi: "Không lấy được file từ Photos (có thể chưa tải được từ iCloud)", en: "The file could not be read from Photos (it may not have downloaded from iCloud)")
        case .checksumMismatch: tr(vi: "File ở đích khác với file đã gửi (checksum không khớp)", en: "The file at the destination differs from the one sent (checksum mismatch)")
        case .foreignFile: tr(vi: "Ở đích đã có một file cùng tên không phải của PhotoVault", en: "The destination already holds a file of that name that PhotoVault did not write")
        case .foreignModified: tr(vi: "File PhotoVault đã ghi bị chương trình khác sửa", en: "A file PhotoVault wrote was changed by another program")
        case .tooLargeForDisk: tr(vi: "File lớn hơn chỗ trống trên máy Mac", en: "The file is larger than the free space on this Mac")
        case .tooLargeForRule: tr(vi: "File lớn hơn giới hạn đặt cho đích này", en: "The file is larger than the limit set for this destination")
        case .permanentError: tr(vi: "Đích không nhận file này", en: "The destination does not accept this file")
        case .deferredTooLong: tr(vi: "Lỗi suốt 30 ngày nên đã bỏ qua", en: "Skipped after failing for 30 days")
        case .resourceMissing: tr(vi: "File gốc không còn trong Photos", en: "The original is no longer in Photos")
        }
    }

    /// The case name of a `DestinationError` as stored in `last_error` ("server(503)", "noSpace"); nil when unknown.
    static func error(_ detail: String) -> String? {
        let name = String(detail.prefix { $0 != "(" })
        let error: DestinationError? = switch name {
        case "unauthorized": .unauthorized
        case "reauthRequired": .reauthRequired
        case "rateLimited": .rateLimited(retryAfter: nil)
        case "server": .server(status: 500)
        case "offline": .offline
        case "noSpace": .noSpace
        case "quotaExceeded": .quotaExceeded
        case "dailyCapReached": .dailyCapReached
        case "bookmarkInvalid": .bookmarkInvalid
        case "folderMissing", "rootMissing", "notFound": .notFound
        case "folderTrashed", "rootTrashed": .rootTrashed
        case "checksumMismatch": .checksumMismatch(expected: "", actual: "")
        case "foreignFile": .foreignFile
        case "foreignModified": .foreignModified
        case "alreadyExists", "sessionExpired": .sessionExpired
        default: nil
        }
        if let error { return ErrorText.message(for: error) }
        switch name {
        case "itemRejected": return tr(vi: "Đích từ chối file này", en: "The destination rejected this file")
        case "transient", "unexpected error": return tr(vi: "Lỗi tạm thời", en: "A temporary error")
        default: return nil
        }
    }

    /// An import item that was not imported.
    public static func importItem(state: ImportItemState, reason: String?) -> String? {
        switch (state, reason) {
        case (.failed, "read"): tr(vi: "Không đọc được file", en: "The file could not be read")
        case (.failed, "missing"): tr(vi: "File không còn ở thư mục nguồn hoặc đã đổi trong lúc nhập", en: "The file was gone from the source or changed during the import")
        case (.failed, "hash"): tr(vi: "Không đọc được nội dung để so với các file đã backup", en: "Its content could not be read to compare with the backed-up files")
        case (.failed, _): tr(vi: "Không nhập được file", en: "The file could not be imported")
        case (.unsupported, "companion"): tr(vi: "File đi kèm, không phải ảnh hay video", en: "A companion file, not a photo or video")
        case (.unsupported, _): tr(vi: "Không phải ảnh hay video mà PhotoVault đọc được", en: "Not a photo or video PhotoVault can read")
        case (.cancelled, _): tr(vi: "Lần nhập đã bị huỷ trước khi tới file này", en: "The import was cancelled before this file")
        default: nil
        }
    }

    /// "Trùng với IMG_1234.HEIC (chụp 10/11/2026 09:00), đã backup".
    public static func duplicate(of name: String?, capturedAt: Date?, calendar: Calendar = .current) -> String {
        let file = name ?? tr(vi: "một file", en: "a file")
        guard let capturedAt else { return tr(vi: "Trùng với \(file) đã backup", en: "Same as \(file), already backed up") }
        let when = RelativeTimeText.dateTime(capturedAt, calendar: calendar)
        return tr(vi: "Trùng với \(file) (chụp \(when)) đã backup", en: "Same as \(file) (taken \(when)), already backed up")
    }

    /// For a file the import could not read: how to try again.
    public static var reimportHint: String {
        tr(vi: "Để đọc lại file lỗi, hãy nhập lại thư mục này; file đã backup sẽ được nhận ra là trùng.",
           en: "To read failed files again, import this folder again; files already backed up are recognised as duplicates.")
    }
}
