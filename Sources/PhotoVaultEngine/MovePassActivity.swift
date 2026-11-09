import Foundation
import PhotoVaultCore

/// What one destination's move pass changed, as activity rows (FR-63): one row per renamed folder
/// and one per target folder of moved files, or a single summary when there are more than
/// `maxRows` (a first sync can name thousands of day folders). Rows name folders, never files.
struct MovePassActivity: Sendable {
    static let maxRows = 5

    private(set) var renames: [(from: String, to: String)] = []
    /// Target folder name → files moved into it, in first-seen order.
    private(set) var moves: [(folder: String, count: Int)] = []

    var isEmpty: Bool { renames.isEmpty && moves.isEmpty }

    mutating func renamed(from: String, to: String) { renames.append((from, to)) }

    mutating func moved(into folder: String) {
        if let index = moves.firstIndex(where: { $0.folder == folder }) {
            moves[index].count += 1
        } else {
            moves.append((folder, 1))
        }
    }

    /// The rows to record, oldest first.
    func events() -> [(kind: ActivityKind, message: String)] {
        var rows: [(ActivityKind, String)] = []
        if renames.count <= Self.maxRows {
            rows += renames.map { (.renamed, Self.renameText($0.from, $0.to)) }
        } else if let first = renames.first {
            rows.append((.renamed, tr(
                vi: "Đã đổi tên \(renames.count) thư mục, ví dụ \(Self.renameText(first.from, first.to))",
                en: "Renamed \(renames.count) folders, for example \(Self.renameText(first.from, first.to))")))
        }
        if moves.count <= Self.maxRows {
            rows += moves.map { (.moved, Self.moveText(count: $0.count, folder: $0.folder)) }
        } else {
            let files = moves.reduce(0) { $0 + $1.count }
            rows.append((.moved, tr(
                vi: "Đã chuyển \(files) file sang \(moves.count) thư mục khác",
                en: "Moved \(files) files into \(moves.count) other folders")))
        }
        return rows
    }

    static func renameText(_ from: String, _ to: String) -> String { "“\(from)” → “\(to)”" }

    static func moveText(count: Int, folder: String) -> String {
        tr(vi: "Đã chuyển \(count) file vào “\(folder)”",
           en: "\(L10n.plural(count, one: "Moved 1 file", other: "Moved \(count) files")) into “\(folder)”")
    }
}
