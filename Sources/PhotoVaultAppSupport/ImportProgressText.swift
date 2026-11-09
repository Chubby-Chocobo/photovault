import Foundation
import PhotoVaultCore
import PhotoVaultEngine

/// Strings and numbers for one-time imports, shared by Settings and the menu bar. Counts only; the
/// folder's name is shown in the app and never reaches logs or the activity list.
public enum ImportProgressText {
    public static func statusLabel(_ status: SourceStatus) -> String {
        switch status {
        case .scanning: tr(vi: "Đang đọc thư mục…", en: "Reading folder…")
        case .importing: tr(vi: "Đang upload…", en: "Uploading…")
        case .offline: tr(vi: "Thư mục không truy cập được, sẽ tiếp tục khi có lại", en: "Folder is not reachable; it will continue when it is back")
        case .completed: tr(vi: "Hoàn tất", en: "Done")
        case .cancelled: tr(vi: "Đã huỷ", en: "Cancelled")
        }
    }

    /// One bar for both stages: reading fills the first half, uploading the second. With nothing to
    /// upload the second half counts as done once everything is read.
    public static func fraction(_ item: ImportSnapshot) -> Double {
        if item.status == .completed { return 1 }
        let read = item.found > 0 ? ProgressText.fraction(done: item.processed, total: item.found) : 0
        let uploaded: Double
        if item.filesTotal > 0 {
            uploaded = ProgressText.fraction(done: item.filesUploaded, total: item.filesTotal)
        } else {
            uploaded = item.status == .importing ? 1 : 0
        }
        return 0.5 * read + 0.5 * uploaded
    }

    /// "Đọc 1.240/3.500 · Upload 800/1.100 · 120 đã có"; empty while the folder is still being listed.
    public static func progressLine(_ item: ImportSnapshot) -> String {
        guard item.found > 0 else { return "" }
        var parts = [tr(vi: "Đọc ", en: "Read ") + "\(VietnameseFormat.integer(item.processed))/\(VietnameseFormat.integer(item.found))"]
        if item.filesTotal > 0 {
            parts.append("Upload \(VietnameseFormat.integer(item.filesUploaded))/\(VietnameseFormat.integer(item.filesTotal))")
        }
        if item.duplicates > 0 {
            parts.append(tr(vi: "\(VietnameseFormat.integer(item.duplicates)) đã có", en: "\(VietnameseFormat.integer(item.duplicates)) already backed up"))
        }
        return parts.joined(separator: " · ")
    }

    /// "12 mới · 5 đã có · 2 bỏ qua · 1 lỗi"
    public static func summaryLine(_ item: ImportSnapshot) -> String {
        let new = VietnameseFormat.integer(item.imported)
        let known = VietnameseFormat.integer(item.duplicates)
        let skipped = VietnameseFormat.integer(item.unsupported)
        let failed = VietnameseFormat.integer(item.failed)
        return tr(
            vi: "\(new) mới · \(known) đã có · \(skipped) bỏ qua · \(failed) lỗi",
            en: "\(new) new · \(known) already backed up · \(skipped) skipped · \(failed) failed")
    }

    public static func menuTitle(folderName: String) -> String {
        tr(vi: "Nhập từ “\(folderName)”", en: "Importing from “\(folderName)”")
    }

    /// "+ 2 lần nhập khác"; nil when there is no other.
    public static func moreImports(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return tr(vi: "+ \(count) lần nhập khác", en: "+ \(count) more \(L10n.plural(count, one: "import", other: "imports"))")
    }

    /// Imports that still have work (or wait for their folder), newest first.
    public static func running(_ imports: [ImportSnapshot]) -> [ImportSnapshot] { imports.filter { $0.status.isOpen } }
    public static func finished(_ imports: [ImportSnapshot]) -> [ImportSnapshot] { imports.filter { !$0.status.isOpen } }
}

/// The notification for a finished import. It may name the folder (it only appears on this Mac).
public enum ImportNotificationText {
    public static func make(folderName: String, imported: Int, known: Int) -> (title: String, body: String) {
        let new = VietnameseFormat.integer(imported)
        let have = VietnameseFormat.integer(known)
        return (
            tr(vi: "Nhập ảnh xong", en: "Import finished"),
            tr(
                vi: "Đã nhập xong “\(folderName)”: \(new) ảnh mới, \(have) đã có",
                en: "Finished importing “\(folderName)”: \(new) new \(L10n.plural(imported, one: "photo", other: "photos")), \(have) already backed up"))
    }
}
