import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Which provisional assets could possibly need a header read, from the destinations alone. This
/// only narrows the walk; `Eligibility.needsClassification` still decides per asset.
struct ClassifyScope: Sendable, Equatable {
    /// Some destination takes camera or saved photos of any age.
    var everything = false
    /// Assets inserted at or after this moment are in the window of some destination.
    var windowStart: Date?
    /// Assets of this day or later are in scope of some `since` destination.
    var sinceDay: ArchiveDay?

    init(destinations: [DestinationRecord]) {
        for destination in destinations
        where destination.rules.categories.contains(.camera) || destination.rules.categories.contains(.saved) {
            switch destination.scope {
            case .full: everything = true
            case .newOnly: widenWindow(destination.baselineAt)
            case .since(let day):
                widenWindow(destination.baselineAt)
                sinceDay = sinceDay.map { min($0, day) } ?? day
            }
        }
    }

    private mutating func widenWindow(_ baseline: Date?) {
        guard let baseline else { return }
        windowStart = windowStart.map { min($0, baseline) } ?? baseline
    }

    var isEmpty: Bool { !everything && windowStart == nil && sinceDay == nil }
}

extension EngineQueries {
    /// Position in the classify order: inserted assets first, then newest first, ties by key.
    struct ProvisionalCursor: Sendable, Equatable {
        var uninserted: Bool
        var creation: String
        var key: String
    }

    struct ProvisionalEntry: Sendable {
        var key: AssetKey
        var cursor: ProvisionalCursor
    }

    /// The next `limit` provisional assets after `cursor`, in classify order, limited to those the
    /// scope can reach. Each page is an index range scan from the cursor, so walking all pages
    /// reads every row once.
    static func provisionalPage(
        _ db: Database, after cursor: ProvisionalCursor?, limit: Int, scope: ClassifyScope
    ) throws -> [ProvisionalEntry] {
        guard !scope.isEmpty, limit > 0 else { return [] }
        var entries: [ProvisionalEntry] = []
        for uninserted in [false, true] {
            // Groups before the cursor are done.
            if cursor?.uninserted == true, !uninserted { continue }
            guard let filter = scopeFilter(scope, uninserted: uninserted) else { continue }
            let start = cursor?.uninserted == uninserted ? cursor : nil
            var arguments: [any DatabaseValueConvertible] = [uninserted]
            var seek = ""
            if let start {
                seek = "AND (COALESCE(creation_date, '') < ? OR (COALESCE(creation_date, '') = ? AND asset_key < ?))"
                arguments += [start.creation, start.creation, start.key]
            }
            arguments += filter.arguments
            arguments.append(limit - entries.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT asset_key, COALESCE(creation_date, '') AS creation FROM asset
                WHERE category_provisional = 1 AND deleted_at IS NULL AND (inserted_at IS NULL) = ? \(seek) \(filter.sql)
                ORDER BY COALESCE(creation_date, '') DESC, asset_key DESC LIMIT ?
                """, arguments: StatementArguments(arguments))
            for row in rows {
                let raw: String = row["asset_key"]
                guard let key = AssetKey(rawValue: raw) else { continue }
                entries.append(ProvisionalEntry(
                    key: key, cursor: ProvisionalCursor(uninserted: uninserted, creation: row["creation"], key: raw)))
            }
            if entries.count >= limit { break }
        }
        return entries
    }

    /// Extra WHERE terms for one group; nil when nothing in the group can qualify.
    private static func scopeFilter(_ scope: ClassifyScope, uninserted: Bool) -> (sql: String, arguments: [any DatabaseValueConvertible])? {
        if scope.everything { return ("", []) }
        var terms: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if !uninserted, let start = scope.windowStart {
            terms.append("inserted_at >= ?")
            arguments.append(start)
        }
        if let day = scope.sinceDay {
            terms.append("creation_day >= ?")
            arguments.append(day.description)
        }
        guard !terms.isEmpty else { return nil }
        return ("AND (\(terms.joined(separator: " OR ")))", arguments)
    }
}
