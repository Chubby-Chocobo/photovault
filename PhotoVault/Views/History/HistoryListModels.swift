import Foundation
import Observation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultStore

/// One paged list of transfer events. Pages come from the store off the main thread; a reload that is overtaken
/// by a newer one (the owner typed again) is dropped.
@MainActor
@Observable
final class EventListModel {
    private(set) var rows: [TransferEventRow] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var filter = TransferEventFilter()
    @ObservationIgnored private var generation = 0

    func reload(_ filter: TransferEventFilter, app: AppModel) async {
        generation += 1
        let current = generation
        isLoading = true
        let page = try? await app.historyRead { db in try HistoryRepository.events(db, filter: filter) }
        guard current == generation else { return }
        self.filter = filter
        rows = page ?? []
        hasMore = rows.count == HistoryRepository.pageSize
        isLoading = false
    }

    func loadMore(app: AppModel) async {
        guard hasMore, !isLoading, let cursor = rows.last?.cursor else { return }
        let current = generation
        let filter = filter
        isLoading = true
        let page = try? await app.historyRead { db in try HistoryRepository.events(db, filter: filter, after: cursor) }
        guard current == generation else { return }
        rows += page ?? []
        hasMore = (page?.count ?? 0) == HistoryRepository.pageSize
        isLoading = false
    }

    /// Every row of the current filter, page by page, as CSV.
    func exportCSV(app: AppModel, suggestedName: String) async {
        guard let store = app.env?.store else { return }
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
    private(set) var filter: ImportItemFilter?
    @ObservationIgnored private var generation = 0

    func reload(_ filter: ImportItemFilter, app: AppModel) async {
        generation += 1
        let current = generation
        isLoading = true
        let page = try? await app.historyRead { db in try ImportHistoryRepository.items(db, filter: filter) }
        guard current == generation else { return }
        self.filter = filter
        rows = page ?? []
        hasMore = rows.count == HistoryRepository.pageSize
        isLoading = false
    }

    func loadMore(app: AppModel) async {
        guard hasMore, !isLoading, let filter, let last = rows.last?.relativePath else { return }
        let current = generation
        isLoading = true
        let page = try? await app.historyRead { db in try ImportHistoryRepository.items(db, filter: filter, after: last) }
        guard current == generation else { return }
        rows += page ?? []
        hasMore = (page?.count ?? 0) == HistoryRepository.pageSize
        isLoading = false
    }

    func exportCSV(app: AppModel, suggestedName: String) async {
        guard let store = app.env?.store, let filter else { return }
        await app.exportHistoryCSV(suggestedName: suggestedName, header: HistoryCSV.importHeader) { (after: String?) in
            let page = try await store.read { db in try ImportHistoryRepository.items(db, filter: filter, after: after, limit: 1_000) }
            return (page.map(HistoryCSV.importLine), page.count == 1_000 ? page.last?.relativePath : nil)
        }
    }
}
