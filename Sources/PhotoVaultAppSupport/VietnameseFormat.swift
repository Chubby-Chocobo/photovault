import Foundation

/// Number and size formatting in the Vietnamese style: `.` groups thousands, `,` starts decimals.
/// Sizes are binary (1 GB = 2^30 bytes) so they match the watermarks in Settings, which are GiB.
public enum VietnameseFormat {
    /// `48210` -> `"48.210"`.
    public static func integer(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var grouped = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { grouped.append(".") }
            grouped.append(character)
        }
        return (value < 0 ? "-" : "") + String(grouped.reversed())
    }

    /// `3.25, 1` -> `"3,3"`. Always prints `fractionDigits` decimals.
    public static func decimal(_ value: Double, fractionDigits: Int) -> String {
        let digits = max(0, fractionDigits)
        let text = String(format: "%.\(digits)f", value)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let whole = Int(parts[0]).map(integer) ?? String(parts[0])
        guard parts.count == 2 else { return whole }
        return whole + "," + parts[1]
    }

    /// `3.4 GiB` -> `"3,4 GB"`; TB with two decimals, GB with one, smaller units without decimals.
    public static func bytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        let units: [(String, Double, Int)] = [
            ("TB", 1_099_511_627_776, 2), ("GB", 1_073_741_824, 1), ("MB", 1_048_576, 0), ("KB", 1024, 0),
        ]
        for (name, size, digits) in units where value >= size {
            return decimal(value / size, fractionDigits: digits) + " " + name
        }
        return integer(Int(value)) + " B"
    }

    /// Whole or fractional gigabytes for watermark fields: `15 * GiB` -> `"15,0 GB"`.
    public static func gigabytes(_ bytes: Int64) -> String {
        decimal(Double(bytes) / Double(GiB), fractionDigits: 1) + " GB"
    }

    public static let GiB: Int64 = 1 << 30
}
