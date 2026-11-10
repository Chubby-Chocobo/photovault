import Foundation

/// Decimal numbers and byte sizes in the interface language. Sizes are binary (1 GB = 2^30 bytes) so
/// they match the watermarks in Settings. Lives in Core so the engine can write sizes into activity rows.
public enum SizeText {
    private static var decimalSeparator: String { L10n.language == .vi ? "," : "." }

    /// `3.25, 1` -> `"3,3"`. Always prints `fractionDigits` decimals.
    public static func decimal(_ value: Double, fractionDigits: Int) -> String {
        let digits = max(0, fractionDigits)
        let text = String(format: "%.\(digits)f", value)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let whole = Int(parts[0]).map(L10n.integer) ?? String(parts[0])
        guard parts.count == 2 else { return whole }
        return whole + decimalSeparator + parts[1]
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
        return L10n.integer(Int(value)) + " B"
    }
}
