import Foundation
import PhotoVaultCore
import PhotoVaultStore
import GRDB

/// What one destination's move pass changed, written to the activity list (FR-63) as one rename row
/// and one move row per destination and hour: later passes grow the open row. Rows name folders,
/// never files.
struct MovePassActivity: Sendable {
    static let window: TimeInterval = 3600

    private(set) var renameCount = 0
    private(set) var lastRename: (from: String, to: String)?
    private(set) var moveCount = 0
    private(set) var lastMoveFolder: String?

    var isEmpty: Bool { renameCount == 0 && moveCount == 0 }

    mutating func renamed(from: String, to: String) {
        renameCount += 1
        lastRename = (from, to)
    }

    mutating func moved(into folder: String) {
        moveCount += 1
        lastMoveFolder = folder
    }

    func write(_ db: Database, destinationId: DestinationID, now: Date) throws {
        let fresh: (Date) -> Bool = { now.timeIntervalSince($0) < Self.window }
        if let last = lastRename {
            try ActivityRepository.recordCoalesced(
                db, group: "renamed", kind: .renamed, destinationId: destinationId, count: renameCount, now: now,
                sameWindow: fresh) { total in Self.renameText(total: total, from: last.from, to: last.to) }
        }
        if let folder = lastMoveFolder {
            try ActivityRepository.recordCoalesced(
                db, group: "moved", kind: .moved, destinationId: destinationId, count: moveCount, now: now,
                sameWindow: fresh) { total in Self.moveText(total: total, folder: folder) }
        }
    }

    /// "“2026-04-26” → “2026-04-26 Hà Nội”", or a count with the latest one.
    static func renameText(total: Int, from: String, to: String) -> String {
        let pair = "“\(from)” → “\(to)”"
        guard total > 1 else { return pair }
        return tr(vi: "Đã đổi tên \(L10n.integer(total)) thư mục, gần nhất \(pair)",
                  en: "Renamed \(L10n.integer(total)) folders, latest \(pair)")
    }

    static func moveText(total: Int, folder: String) -> String {
        guard total > 1 else { return tr(vi: "Đã chuyển 1 file vào “\(folder)”", en: "Moved 1 file into “\(folder)”") }
        return tr(vi: "Đã chuyển \(L10n.integer(total)) file, gần nhất vào “\(folder)”",
                  en: "Moved \(L10n.integer(total)) files, latest into “\(folder)”")
    }
}
