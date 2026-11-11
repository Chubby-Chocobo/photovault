import Foundation

/// A status line the popup shows on one line of fixed height. It comes in parts so a line that does not fit
/// gives up its least useful part first:
/// 1. `place` (where the file goes, the account) goes away;
/// 2. then `others` (the count of the other files moving);
/// 3. then `lead` (the file name) is cut in the middle, so the file's extension stays.
/// `prefix` (the action, such as "Uploading ") and `detail` (sizes, elapsed time: what shows the work moving)
/// stay whole. `text` is every part as given; `help` is the tooltip, with nothing shortened.
public struct FittedLine: Equatable, Sendable {
    public var prefix: String
    public var lead: String
    public var place: String
    public var detail: String
    public var others: String
    public var help: String

    public init(prefix: String = "", lead: String, place: String = "", detail: String = "", others: String = "", help: String? = nil) {
        self.prefix = prefix
        self.lead = lead
        self.place = place
        self.detail = detail
        self.others = others
        self.help = help ?? prefix + lead + place + detail + others
    }

    public var text: String { prefix + lead + place + detail + others }
}
