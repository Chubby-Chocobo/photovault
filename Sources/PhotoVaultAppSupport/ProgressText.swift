import Foundation
import PhotoVaultCore

/// Backfill progress strings (FR-60): counts are assets, not bytes; the ETA follows the asset rate.
public enum ProgressText {
    public static func fraction(done: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// "Còn khoảng 6 ngày"; nil ETA means no completion rate has been observed yet.
    public static func eta(seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return tr(vi: "Đang ước tính…", en: "Estimating…") }
        if seconds < 3600 {
            let n = max(1, Int((seconds / 60).rounded()))
            return tr(vi: "Còn khoảng \(n) phút", en: L10n.plural(n, one: "About \(n) minute left", other: "About \(n) minutes left"))
        }
        if seconds < 86400 {
            let n = Int((seconds / 3600).rounded())
            return tr(vi: "Còn khoảng \(n) giờ", en: L10n.plural(n, one: "About \(n) hour left", other: "About \(n) hours left"))
        }
        let n = Int((seconds / 86400).rounded())
        return tr(vi: "Còn khoảng \(n) ngày", en: L10n.plural(n, one: "About \(n) day left", other: "About \(n) days left"))
    }

    /// "Ước tính theo số asset: ~6.100 asset/ngày"; nil when the rate is unknown.
    public static func rateCaption(remainingAssets: Int, etaSeconds: TimeInterval?) -> String? {
        guard let etaSeconds, etaSeconds > 0, remainingAssets > 0 else { return nil }
        let perDay = Int((Double(remainingAssets) / etaSeconds * 86400).rounded())
        guard perDay > 0 else { return nil }
        let rate = VietnameseFormat.integer(perDay)
        return tr(vi: "Ước tính theo số asset: ~\(rate) asset/ngày", en: "Estimate by asset count: ~\(rate) assets/day")
    }
}
