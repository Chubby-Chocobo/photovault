import Foundation

/// A local destination root must not contain, or sit inside, another one: the outer destination's walk,
/// integrity check and recovery would see the inner tree (and its `.photovault`) as content.
public enum DestinationNesting {
    public enum Relation: Equatable, Sendable {
        case same, inside, contains
    }

    /// How `candidate` relates to `existing` (both absolute folder paths); nil when they are unrelated.
    public static func relation(of candidate: String, to existing: String) -> Relation? {
        let (a, b) = (normalize(candidate), normalize(existing))
        if a == b { return .same }
        if a.hasPrefix(b == "/" ? "/" : b + "/") { return .inside }
        if b.hasPrefix(a == "/" ? "/" : a + "/") { return .contains }
        return nil
    }

    /// The first existing root `candidate` is nested with, and how.
    public static func conflict(candidate: String, existing: [(name: String, path: String)]) -> (name: String, relation: Relation)? {
        for root in existing {
            if let relation = relation(of: candidate, to: root.path) { return (root.name, relation) }
        }
        return nil
    }

    /// Owner-facing message (Vietnamese, like the rest of the UI).
    public static func message(name: String, relation: Relation) -> String {
        switch relation {
        case .same: "Thư mục này đã là đích “\(name)”."
        case .inside: "Thư mục này nằm trong đích “\(name)”. Hãy chọn một thư mục riêng, không lồng nhau."
        case .contains: "Thư mục này chứa đích “\(name)”. Hãy chọn một thư mục riêng, không lồng nhau."
        }
    }

    private static func normalize(_ path: String) -> String {
        var normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }
}
