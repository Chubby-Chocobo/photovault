import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

/// History lists must stay fast on a library of hundreds of thousands of files: every query walks an index
/// in the order it returns, never the whole table and never a sort of it. Checked on the plan, not on time.
@Suite struct TransferHistoryQueryPlanTests {
    static let files = 200_000

    /// 200k files with an asset, a resource, a job and an event each, plus one import of 200k items.
    private static func largeLibrary() throws -> Store {
        let store = try Store.inMemory()
        try store.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(files))
                INSERT INTO asset (asset_key, asset_key_hash, local_id, media_type, creation_date, first_seen_at, last_seen_at)
                SELECT 'l:' || i, 'h' || i, 'id' || i, 1 + (i % 2), datetime(1700000000 + i * 60, 'unixepoch'),
                       datetime(1700000000, 'unixepoch'), datetime(1700000000, 'unixepoch') FROM n;
                INSERT INTO resource (asset_key, res_type, kind, original_filename, uti, size_bytes, is_raw)
                SELECT asset_key, 1, 'original', 'IMG_' || local_id || '.HEIC', 'public.heic', 1000, 0 FROM asset;
                INSERT INTO upload_job (destination_id, asset_key, res_type, kind, origin, state, done_gen, backfill_run_id, updated_at)
                SELECT 'gdrive', asset_key, 1, 'original', 'backfill', 'done', 1, 1, creation_date FROM asset;
                INSERT INTO transfer_event (at, job_id, destination_id, asset_key, res_type, source_id, origin, run_id, outcome, bytes)
                SELECT updated_at, id, destination_id, asset_key, 1, 'photos', origin, 1,
                       CASE id % 5 WHEN 0 THEN 'failed' ELSE 'uploaded' END, 1000 FROM upload_job;
                INSERT INTO backfill_run (id, trigger, started_at) VALUES (1, 'library', datetime(1700000000, 'unixepoch'));
                INSERT INTO import_item (source_id, rel_path, group_key, uti, size_bytes, state)
                SELECT 'folder-1', 'dir/' || local_id || '.jpg', local_id, 'public.jpeg', 10,
                       CASE media_type WHEN 1 THEN 'imported' ELSE 'duplicate' END FROM asset;
                """)
        }
        return store
    }

    private static let store = Result { try largeLibrary() }

    private func plan(_ sql: String, _ arguments: StatementArguments) throws -> String {
        try Self.store.get().read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }.joined(separator: " | ")
        }
    }

    /// The plan reads `table` through an index and never sorts the result.
    private func expectIndexed(_ plan: String, table: String, index: String) {
        #expect(plan.contains("\(table) USING INDEX \(index)") || plan.contains("\(table) USING COVERING INDEX \(index)"), "\(plan)")
        #expect(!plan.contains("SCAN \(table) ") && !plan.hasSuffix("SCAN \(table)"), "\(plan)")
        #expect(!plan.contains("TEMP B-TREE FOR ORDER BY"), "\(plan)")
    }

    @Test func thePhotosListWalksTheSourceIndexWhateverTheFilters() throws {
        let cursor = HistoryCursor(at: Date(timeIntervalSince1970: 1_705_000_000), id: 90_000)
        let filters = [
            TransferEventFilter(),
            TransferEventFilter(search: "img_42", outcomes: [.failed, .skipped]),
            TransferEventFilter(destinationId: .googleDrive, media: .raw, from: Date(timeIntervalSince1970: 1_700_000_000)),
            TransferEventFilter(capturedFrom: Date(timeIntervalSince1970: 1_701_000_000), deletedFromLibraryOnly: true),
        ]
        for filter in filters {
            let query = HistoryRepository.eventQuery(filter, after: cursor, limit: 200)
            expectIndexed(try plan(query.sql, query.arguments), table: "e", index: "transfer_event_source_at")
        }
    }

    @Test func aRunListWalksTheRunIndex() throws {
        let query = HistoryRepository.eventQuery(TransferEventFilter(scope: .run(1), outcomes: [.failed]), after: nil, limit: 200)
        expectIndexed(try plan(query.sql, query.arguments), table: "e", index: "transfer_event_run_at")
    }

    @Test func theTimelineReadsTheOutcomeIndexForItsRange() throws {
        let query = HistoryRepository.timelineQuery(
            from: Date(timeIntervalSince1970: 1_700_000_000), until: Date(timeIntervalSince1970: 1_702_000_000), destinationId: .googleDrive)
        let plan = try plan(query.sql, query.arguments)
        #expect(plan.contains("USING INDEX transfer_event_outcome_at") || plan.contains("USING COVERING INDEX transfer_event_outcome_at"), "\(plan)")
        #expect(!plan.contains("SCAN transfer_event"), "\(plan)")
    }

    @Test func importItemsWalkAnIndexInPathOrder() throws {
        for filter in [
            ImportItemFilter(sourceId: SourceID(rawValue: "photos")!),
            ImportItemFilter(sourceId: SourceID(rawValue: "photos")!, states: [.duplicate], search: "id4"),
            ImportItemFilter(sourceId: SourceID(rawValue: "photos")!, states: [.failed, .cancelled]),
        ] {
            let query = ImportHistoryRepository.itemQuery(filter, after: "dir/id5.jpg", limit: 200)
            let plan = try plan(query.sql, query.arguments)
            #expect(plan.contains("SEARCH i USING"), "\(plan)")
            #expect(!plan.contains("SCAN i") && !plan.contains("TEMP B-TREE FOR ORDER BY"), "\(plan)")
        }
    }

    @Test func runTotalsAndFileStatusesUseIndexes() throws {
        let totals = try plan("""
            SELECT e.outcome, COUNT(*) FROM transfer_event e
            WHERE e.run_id = ?1 AND e.id = (SELECT MAX(id) FROM transfer_event WHERE job_id = e.job_id AND run_id = ?1) GROUP BY e.outcome
            """, [1])
        #expect(totals.contains("transfer_event_run_at") && totals.contains("transfer_event_job"), "\(totals)")
        #expect(!totals.contains("SCAN e") && !totals.contains("SCAN transfer_event"), "\(totals)")
        let waiting = try plan("SELECT COUNT(*) FROM upload_job WHERE backfill_run_id = ? AND state IN ('pending', 'uploading') AND origin IN ('backfill', 'destinationBackfill')", [1])
        #expect(waiting.contains("upload_job_backfill_run"), "\(waiting)")
    }

    @Test func aPageOfTheLargeLibraryHasTheNewestFirst() throws {
        let page = try Self.store.get().read { db in try HistoryRepository.events(db, filter: TransferEventFilter(), limit: 3) }
        #expect(page.map(\.fileName) == ["IMG_id200000.HEIC", "IMG_id199999.HEIC", "IMG_id199998.HEIC"])
    }
}
