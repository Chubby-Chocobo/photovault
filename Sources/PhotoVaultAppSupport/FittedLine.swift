import Foundation

/// A status line the popup shows on one line of fixed height. It is split in three so a narrow line gives
/// up its least useful part first:
/// - `detail` (sizes, elapsed time, other files) is kept whole: it is what shows the work moving;
/// - `lead` ends with the file name, so shortening it in the middle keeps the file's extension;
/// - `place` (where the file goes, the account) is cut first.
/// `text` is the whole line, for the tooltip and accessibility.
public struct FittedLine: Equatable, Sendable {
    public var lead: String
    public var place: String
    public var detail: String

    public init(lead: String, place: String = "", detail: String = "") {
        self.lead = lead
        self.place = place
        self.detail = detail
    }

    public var text: String { lead + place + detail }
}
