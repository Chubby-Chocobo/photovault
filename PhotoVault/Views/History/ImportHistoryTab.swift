import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultStore
import SwiftUI

/// Every one-time import (folder, Google Drive, Dropbox), newest first; an import's summary and files beside it.
struct ImportHistoryTab: View {
    @Environment(AppModel.self) private var model
    @State private var imports: [ImportRunRow] = []
    @State private var selection: SourceID?
    @State private var state: ImportItemState?
    @State private var search = ""
    @State private var list = ImportItemListModel()
    @State private var selectedItem: ImportItemRow.ID?

    var body: some View {
        HSplitView {
            List(imports, selection: $selection) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.source.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    Text(RelativeTimeText.dateTime(row.source.createdAt)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if imports.isEmpty { Text(tr(vi: "Chưa nhập lần nào.", en: "No imports yet.")).foregroundStyle(.secondary) }
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            detail.frame(minWidth: 600)
        }
        .task { await loadImports() }
        .task(id: TaskKey(source: selection, state: state, search: search)) {
            guard let selection else { return }
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await list.reload(ImportItemFilter(sourceId: selection, states: state.map { [$0] } ?? [], search: search), app: model)
        }
    }

    private struct TaskKey: Equatable {
        var source: SourceID?
        var state: ImportItemState?
        var search: String
    }

    @ViewBuilder private var detail: some View {
        if let row = imports.first(where: { $0.id == selection }) {
            VStack(spacing: 0) {
                summary(row).padding(12)
                Divider()
                HSplitView {
                    ImportItemTable(list: list, selection: $selectedItem).frame(minWidth: 360)
                    Group {
                        if let item = list.rows.first(where: { $0.id == selectedItem }) {
                            FileDetailView(file: .importItem(item))
                        } else {
                            Text(tr(vi: "Chọn một file để xem chi tiết.", en: "Select a file to see its details."))
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 240, idealWidth: 280)
                }
            }
        } else {
            Text(tr(vi: "Chọn một lần nhập để xem các file của nó.", en: "Select an import to see its files."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ row: ImportRunRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.source.displayName).font(.headline)
            Text(HistoryRunText.period(start: row.source.createdAt, end: row.source.finishedAt)).font(.callout)
            Text(HistoryRunText.importTotals(row.totals)).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField(tr(vi: "Tìm theo đường dẫn", en: "Search paths"), text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 160)
                Picker(tr(vi: "Kết quả", en: "Result"), selection: $state) {
                    Text(tr(vi: "Mọi kết quả", en: "All results")).tag(ImportItemState?.none)
                    ForEach(ImportItemState.allCases, id: \.self) { Text(HistoryText.importState($0)).tag(Optional($0)) }
                }
                .fixedSize()
                Spacer()
                Button(tr(vi: "Thử lại các upload lỗi", en: "Retry failed uploads")) {
                    Task {
                        await model.retryFailedUploads(ofImport: row.id)
                        await loadImports()
                    }
                }
                .disabled(row.failedUploads == 0)
                Button(tr(vi: "Xuất CSV…", en: "Export CSV…"), systemImage: "square.and.arrow.up") {
                    Task { await list.exportCSV(app: model, suggestedName: "PhotoVault-import.csv") }
                }
                .disabled(list.rows.isEmpty)
            }
        }
    }

    private func loadImports() async {
        imports = (try? await model.historyRead { db in try ImportHistoryRepository.imports(db) }) ?? []
        if selection == nil { selection = imports.first?.id }
    }
}
