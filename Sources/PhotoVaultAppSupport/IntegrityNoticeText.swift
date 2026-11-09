import Foundation
import PhotoVaultCore

/// The message shown after "Kiểm tra ngay" (FR-76).
public enum IntegrityNoticeText {
    public static func make(missing: Int, mismatched: Int, skippedNames: [String]) -> String {
        var parts: [String] = []
        if missing > 0 {
            let n = VietnameseFormat.integer(missing)
            parts.append(tr(vi: "thiếu \(n) file", en: L10n.plural(missing, one: "\(n) file missing", other: "\(n) files missing")))
        }
        if mismatched > 0 {
            let n = VietnameseFormat.integer(mismatched)
            parts.append(
                tr(
                    vi: "\(n) file lệch checksum",
                    en: L10n.plural(
                        mismatched, one: "\(n) file with a checksum mismatch", other: "\(n) files with a checksum mismatch")))
        }
        let names = skippedNames.joined(separator: ", ")
        let skipped = skippedNames.isEmpty
            ? ""
            : tr(
                vi: "Chưa kiểm tra được \(names) vì đích chưa truy cập được.",
                en: "Couldn't check \(names) because the destination can't be reached yet.")
        if parts.isEmpty {
            return skippedNames.isEmpty
                ? tr(
                    vi: "Kiểm tra xong: không thiếu file nào và không file nào lệch checksum.",
                    en: "Check finished: no files missing and no checksum mismatches.")
                : tr(
                    vi: "Kiểm tra xong các đích còn lại: không có vấn đề. \(skipped)",
                    en: "Check finished for the other destinations: no problems. \(skipped)")
        }
        let list = parts.joined(separator: ", ")
        let found = tr(vi: "Kiểm tra xong: \(list). Xem trong menu bar.", en: "Check finished: \(list). See the menu bar.")
        return skipped.isEmpty ? found : found + " " + skipped
    }
}
