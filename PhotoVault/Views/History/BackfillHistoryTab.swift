import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultStore
import SwiftUI

/// Every backfill run, newest first; a run's summary and files beside it.
struct BackfillHistoryTab: View {
    @Environment(AppModel.self) private var model
    var refresh = 0
    @State private var runs: [BackfillRunRow] = []
    @State private var selection: BackfillRunRow.ID?
    @State private var filter = HistoryFilterState()
    @State private var list = EventListModel()

    var body: some View {
        HSplitView {
            List(runs, selection: $selection) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text(HistoryRunText.title(run, destinationNames: model.destinationNames)).font(.callout.weight(.medium))
                    Text(HistoryText.time(run.startedAt, approximate: run.approximate)).font(.caption).foregroundStyle(.secondary)
                    if run.finishedAt == nil { Text(tr(vi: "Đang chạy", en: "Running")).font(.caption).foregroundStyle(.orange) }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if runs.isEmpty { Text(tr(vi: "Chưa có lần backfill nào.", en: "No backfill yet.")).foregroundStyle(.secondary) }
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
            detail.frame(minWidth: 600)
        }
        .task(id: refresh) { await loadRuns() }
        .task(id: TaskKey(run: selection, filter: filter, refresh: refresh)) {
            guard let selection else { return }
            if !filter.search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await list.reload(filter.filter(scope: .run(selection), now: Date(), calendar: .current), app: model)
        }
    }

    private struct TaskKey: Equatable {
        var run: Int64?
        var filter: HistoryFilterState
        var refresh: Int
    }

    @ViewBuilder private var detail: some View {
        if let run = runs.first(where: { $0.id == selection }) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(HistoryRunText.title(run, destinationNames: model.destinationNames)).font(.headline)
                    Text(HistoryRunText.period(start: run.startedAt, end: run.finishedAt, approximate: run.approximate)).font(.callout)
                    Text(HistoryRunText.totals(run.totals)).font(.callout).foregroundStyle(.secondary)
                    if run.retryable > 0 {
                        Text(tr(vi: "\(L10n.integer(run.retryable)) file đang lỗi hoặc bị bỏ qua, có thể thử lại",
                                en: L10n.plural(run.retryable, one: "1 file failed or was skipped and can be retried",
                                                other: "\(L10n.integer(run.retryable)) files failed or were skipped and can be retried")))
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if run.approximate { Text(HistoryText.approximateNote).font(.caption).foregroundStyle(.secondary) }
                    HistoryFilterBar(state: $filter, destinations: model.destinations)
                    HStack {
                        Button(tr(vi: "Thử lại các file lỗi", en: "Retry failed files")) {
                            Task {
                                await model.retryFailedFiles(ofRun: run.id)
                                await loadRuns()
                            }
                        }
                        .disabled(run.retryable == 0)
                        Spacer()
                        Button(tr(vi: "Xuất CSV…", en: "Export CSV…"), systemImage: "square.and.arrow.up") {
                            Task { await list.exportCSV(app: model, suggestedName: "PhotoVault-backfill-\(run.id).csv") }
                        }
                        .disabled(list.rows.isEmpty)
                    }
                }
                .padding(12)
                Divider()
                EventListView(list: list)
            }
        } else {
            Text(tr(vi: "Chọn một lần backfill để xem các file của nó.", en: "Select a backfill run to see its files."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadRuns() async {
        runs = (try? await model.historyRead { db in try BackfillRunRepository.fetchAll(db) }) ?? []
        if selection == nil { selection = runs.first?.id }
    }
}
