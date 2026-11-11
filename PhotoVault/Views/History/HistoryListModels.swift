import Foundation
import GRDB
import Observation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultStore

/// The one read a list has in flight. A newer read cancels it, and so does cancelling the caller (the owner typed
/// again, switched runs or closed the window): GRDB then interrupts the statement instead of finishing a scan nobody
/// will see.
@MainActor
final class LatestRead<Row: Sendable> {
    private var inFlight: Task<[Row]?, Error>?

    func run(app: AppModel, _ body: @escaping @Sendable (Database) throws -> [Row]) async -> Result<[Row], Error> {
        inFlight?.cancel()
        let task = Task { try await app.historyRead(body) }
        inFlight = task
        return await withTaskCancellationHandler {
            await task.result.map { $0 ?? [] }
        } onCancel: {
            task.cancel()
        }
    }
}

/// What a list shows: its rows, whether more pages exist, and whether the last read failed.
enum ListLoad {
    static func failed(_ result: Result<some Any, Error>) -> Bool {
        if case .failure(let error) = result { return !(error is CancellationError) }
        return false
    }

    /// A read cancelled by the owner (typing again, switching away): the rows shown stay until the next read ends.
    static func cancelled(_ result: Result<some Any, Error>) -> Bool {
        if case .failure(let error) = result { return error is CancellationError }
        return false
    }
}

/// One paged list of transfer events. Pages come from the store off the main thread; a reload that is overtaken
/// by a newer one is cancelled and its result dropped.
@MainActor
@Observable
final class EventListModel {
    private(set) var rows: [TransferEventRow] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var filter = TransferEventFilter()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let reads = LatestRead<TransferEventRow>()

    func reload(_ filter: TransferEventFilter, app: AppModel) async {
        generation += 1
        let current = generation
        isLoading = true
        let result = await reads.run(app: app) { db in try HistoryRepository.events(db, filter: filter) }
        guard current == generation else { return }
        isLoading = false
        guard !ListLoad.cancelled(result) else { return }
        self.filter = filter
        rows = (try? result.get()) ?? []
        failed = ListLoad.failed(result)
        hasMore = rows.count == HistoryRepository.pageSize
        isLoading = false
    }

    func loadMore(app: AppModel) async {
        guard hasMore, !isLoading, let cursor = rows.last?.cursor else { return }
        let current = generation
        let filter = filter
        isLoading = true
        let result = await reads.run(app: app) { db in try HistoryRepository.events(db, filter: filter, after: cursor) }
        guard current == generation else { return }
        isLoading = false
        guard !ListLoad.cancelled(result) else { return }
        let page = (try? result.get()) ?? []
        rows += page
        failed = ListLoad.failed(result)
        hasMore = page.count == HistoryRepository.pageSize
        isLoading = false
    }

    /// Every row of the current filter, page by page, as CSV. Only offered once the list shows that filter's rows.
    func exportCSV(app: AppModel, suggestedName: String) async {
        guard !isLoading, let store = app.env?.store else { return }
        let filter = filter
        let names = app.destinationNames
        let zone = TimeZone.current
        await app.exportHistoryCSV(suggestedName: suggestedName, header: HistoryCSV.eventHeader) { (cursor: HistoryCursor?) in
            let page = try await store.read { db in try HistoryRepository.events(db, filter: filter, after: cursor, limit: 1_000) }
            return (page.map { HistoryCSV.eventLine($0, destinationNames: names, timeZone: zone) }, page.count == 1_000 ? page.last?.cursor : nil)
        }
    }
}

/// One paged list of an import's files, in path order.
@MainActor
@Observable
final class ImportItemListModel {
    private(set) var rows: [ImportItemRow] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var filter: ImportItemFilter?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let reads = LatestRead<ImportItemRow>()

    func reload(_ filter: ImportItemFilter, app: AppModel) async {
        generation += 1
        let current = generation
        isLoading = true
        let result = await reads.run(app: app) { db in try ImportHistoryRepository.items(db, filter: filter) }
        guard current == generation else { return }
        isLoading = false
        guard !ListLoad.cancelled(result) else { return }
        self.filter = filter
        rows = (try? result.get()) ?? []
        failed = ListLoad.failed(result)
        hasMore = rows.count == HistoryRepository.pageSize
        isLoading = false
    }

    func loadMore(app: AppModel) async {
        guard hasMore, !isLoading, let filter, let last = rows.last?.relativePath else { return }
        let current = generation
        isLoading = true
        let result = await reads.run(app: app) { db in try ImportHistoryRepository.items(db, filter: filter, after: last) }
        guard current == generation else { return }
        isLoading = false
        guard !ListLoad.cancelled(result) else { return }
        let page = (try? result.get()) ?? []
        rows += page
        failed = ListLoad.failed(result)
        hasMore = page.count == HistoryRepository.pageSize
        isLoading = false
    }

    func exportCSV(app: AppModel, suggestedName: String) async {
        guard !isLoading, let store = app.env?.store, let filter else { return }
        await app.exportHistoryCSV(suggestedName: suggestedName, header: HistoryCSV.importHeader) { (after: String?) in
            let page = try await store.read { db in try ImportHistoryRepository.items(db, filter: filter, after: after, limit: 1_000) }
            return (page.map(HistoryCSV.importLine), page.count == 1_000 ? page.last?.relativePath : nil)
        }
    }
}
