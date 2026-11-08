import Foundation

/// The message shown after "Kiểm tra ngay" (FR-76).
public enum IntegrityNoticeText {
    public static func make(missing: Int, mismatched: Int, skippedNames: [String]) -> String {
        var parts: [String] = []
        if missing > 0 { parts.append("thiếu \(VietnameseFormat.integer(missing)) file") }
        if mismatched > 0 { parts.append("\(VietnameseFormat.integer(mismatched)) file lệch checksum") }
        let skipped = skippedNames.isEmpty
            ? "" : "Chưa kiểm tra được \(skippedNames.joined(separator: ", ")) vì đích chưa truy cập được."
        if parts.isEmpty {
            return skippedNames.isEmpty
                ? "Kiểm tra xong: không thiếu file nào và không file nào lệch checksum."
                : "Kiểm tra xong các đích còn lại: không có vấn đề. \(skipped)"
        }
        let found = "Kiểm tra xong: \(parts.joined(separator: ", ")). Xem trong menu bar."
        return skipped.isEmpty ? found : found + " " + skipped
    }
}
