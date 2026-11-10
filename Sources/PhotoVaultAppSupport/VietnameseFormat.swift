import Foundation
import PhotoVaultCore

/// Number and size formatting for the interface language: in Vietnamese `.` groups thousands and `,`
/// starts decimals; in English the other way round. (The name dates from when the interface was
/// Vietnamese only.) Sizes are binary (1 GB = 2^30 bytes) so they match the watermarks in Settings,
/// which are GiB.
public enum VietnameseFormat {
    /// `48210` -> `"48.210"` (`"48,210"` in English).
    public static func integer(_ value: Int) -> String { L10n.integer(value) }

    /// `3.25, 1` -> `"3,3"`. Always prints `fractionDigits` decimals.
    public static func decimal(_ value: Double, fractionDigits: Int) -> String { SizeText.decimal(value, fractionDigits: fractionDigits) }

    /// `3.4 GiB` -> `"3,4 GB"`; TB with two decimals, GB with one, smaller units without decimals.
    public static func bytes(_ bytes: Int64) -> String { SizeText.bytes(bytes) }

    /// Whole or fractional gigabytes for watermark fields: `15 * GiB` -> `"15,0 GB"`.
    public static func gigabytes(_ bytes: Int64) -> String {
        decimal(Double(bytes) / Double(GiB), fractionDigits: 1) + " GB"
    }

    public static let GiB: Int64 = 1 << 30
}
