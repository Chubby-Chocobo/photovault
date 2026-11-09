import Foundation

/// Backfill progress strings (FR-60): counts are assets, not bytes; the ETA follows the asset rate.
public enum ProgressText {
    public static func fraction(done: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// "Còn khoảng 6 ngày"; nil ETA means no completion rate has been observed yet.
    public static func eta(seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "Đang ước tính…" }
        if seconds < 3600 { return "Còn khoảng \(max(1, Int((seconds / 60).rounded()))) phút" }
        if seconds < 86400 { return "Còn khoảng \(Int((seconds / 3600).rounded())) giờ" }
        return "Còn khoảng \(Int((seconds / 86400).rounded())) ngày"
    }

    /// "Ước tính theo số asset: ~6.100 asset/ngày"; nil when the rate is unknown.
    public static func rateCaption(remainingAssets: Int, etaSeconds: TimeInterval?) -> String? {
        guard let etaSeconds, etaSeconds > 0, remainingAssets > 0 else { return nil }
        let perDay = Int((Double(remainingAssets) / etaSeconds * 86400).rounded())
        guard perDay > 0 else { return nil }
        return "Ước tính theo số asset: ~\(VietnameseFormat.integer(perDay)) asset/ngày"
    }
}
