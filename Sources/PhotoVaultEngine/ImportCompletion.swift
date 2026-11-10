import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Closing a folder import: the status change and its one activity row are written together, and
/// only while the job is still open, so a job finishes once.
enum ImportCompletion {
    /// Counts only, never a folder or file name (the folder's name is shown in Settings).
    static func summaryText(_ counts: [ImportItemState: Int], cancelled: Bool) -> String {
        let new = L10n.integer(counts[.imported] ?? 0)
        let known = L10n.integer(counts[.duplicate] ?? 0)
        let skipped = L10n.integer(counts[.unsupported] ?? 0)
        let failed = L10n.integer(counts[.failed] ?? 0)
        if cancelled {
            return tr(vi: "Đã huỷ nhập: \(new) file mới, \(known) đã có sẵn, \(skipped) bỏ qua, \(failed) lỗi",
                      en: "Import cancelled: \(new) new, \(known) already backed up, \(skipped) skipped, \(failed) failed")
        }
        if counts.values.reduce(0, +) == 0 {
            return tr(vi: "Nhập xong nhưng không có ảnh hay video nào mà app đọc được",
                      en: "Import finished, but it had no photos or videos the app could read")
        }
        return tr(vi: "Đã nhập xong: \(new) file mới, \(known) đã có sẵn, \(skipped) bỏ qua, \(failed) lỗi",
                  en: "Import finished: \(new) new, \(known) already backed up, \(skipped) skipped, \(failed) failed")
    }

    /// - Returns: false when the job was already closed.
    @discardableResult
    static func finish(_ db: Database, id: SourceID, as status: SourceStatus, now: Date) throws -> Bool {
        precondition(!status.isOpen)
        guard let source = try SourceRepository.fetch(db, id: id), source.status.isOpen else { return false }
        try SourceRepository.setStatus(db, id: id, status: status, reason: nil, now: now)
        let counts = try ImportItemRepository.counts(db, sourceId: id)
        try ActivityRepository.record(db, ActivityEvent(at: now, kind: .milestone, message: summaryText(counts, cancelled: status == .cancelled)))
        return true
    }
}
