import Foundation

/// Shortens a display path to a character budget by whole components: the root and the last folder name stay,
/// as many parents next to the last as fit are kept, and the dropped middle becomes one "…". When even that is
/// too long, the last name is cut in the middle. Works on grapheme clusters, so accents and emoji stay whole.
public enum ImportLocationShortener {
    private static let ellipsis = "…"

    public static func shorten(_ path: String, budget: Int) -> String {
        let budget = max(budget, 1)
        guard path.count > budget else { return path }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return path }
        // The root: "/" for an absolute path, "/Volumes/<name>", "~", or the first component of a Drive path.
        var root: String
        if path.hasPrefix("/Volumes/"), parts.count >= 2 {
            root = "/" + parts.removeFirst() + "/" + parts.removeFirst()
        } else if path.hasPrefix("/") {
            root = "/"
        } else {
            root = parts.removeFirst()
        }
        guard let last = parts.last else { return middleTruncate(root, to: budget) }
        let separator = root == "/" ? "" : "/"
        let parents = Array(parts.dropLast())
        let droppedAlready = root == ellipsis
        for keep in stride(from: parents.count, through: 0, by: -1) {
            let kept = parents.suffix(keep)
            var pieces = [root]
            if keep < parents.count && !droppedAlready { pieces.append(ellipsis) }
            let candidate = join(pieces + kept + [last], rootSeparator: separator)
            if candidate.count <= budget { return candidate }
        }
        // Not even root, "…" and the last name fit: cut the name itself.
        let head = droppedAlready || parents.isEmpty ? [root] : [root, ellipsis]
        let prefix = join(head, rootSeparator: separator) + (separator.isEmpty && head.count == 1 ? "" : "/")
        let room = max(budget - prefix.count, 3)
        return prefix + middleTruncate(last, to: room)
    }

    /// The path at each budget, longest first, without repeats: the candidates a view tries in turn.
    public static func variants(_ path: String, budgets: [Int]) -> [String] {
        var seen: [String] = []
        for budget in budgets.sorted(by: >) {
            let text = shorten(path, budget: budget)
            if !seen.contains(text) { seen.append(text) }
        }
        return seen
    }

    private static func join(_ pieces: [String], rootSeparator: String) -> String {
        guard let root = pieces.first else { return "" }
        return root + rootSeparator + pieces.dropFirst().joined(separator: "/")
    }

    /// Keeps the start and the end of `text`, with "…" between, in `limit` characters at most.
    static func middleTruncate(_ text: String, to limit: Int) -> String {
        let characters = Array(text)
        guard characters.count > limit, limit >= 3 else { return characters.count > limit ? String(characters.prefix(max(limit, 1))) : text }
        let room = limit - 1
        let head = (room + 1) / 2
        let tail = room - head
        return String(characters.prefix(head)) + ellipsis + String(characters.suffix(tail))
    }
}
