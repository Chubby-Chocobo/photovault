import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// A paged table of transfer events with the selected file's detail beside it.
struct EventListView: View {
    @Environment(AppModel.self) private var model
    var list: EventListModel
    @State private var selection: TransferEventRow.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                table
                Divider()
                footer
            }
            .frame(minWidth: 460)
            Group {
                if let row = list.rows.first(where: { $0.id == selection }) {
                    FileDetailView(file: .event(row))
                } else {
                    Text(tr(vi: "Chọn một file để xem chi tiết.", en: "Select a file to see its details."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 260, idealWidth: 300)
        }
    }

    private var table: some View {
        Table(list.rows, selection: $selection) {
            TableColumn(tr(vi: "Thời điểm", en: "Time")) { row in
                Text(HistoryText.time(row.at, approximate: row.approximate)).monospacedDigit()
                    .help(row.approximate ? HistoryText.approximateNote : "")
            }
            .width(min: 120, ideal: 140)
            TableColumn(tr(vi: "File", en: "File")) { row in
                HStack(spacing: 4) {
                    Text(row.fileName).lineLimit(1).truncationMode(.middle)
                    if HistoryText.keptAfterDeletion(row) {
                        Image(systemName: "trash").foregroundStyle(.secondary).help(HistoryText.deletedFromLibrary)
                    }
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn(tr(vi: "Đích", en: "Destination")) { row in
                Text(HistoryText.destination(row.destinationId, names: model.destinationNames)).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            TableColumn(tr(vi: "Kết quả", en: "Result")) { row in
                Text(HistoryText.outcome(row.outcome)).foregroundStyle(tint(row.outcome))
            }
            .width(min: 70, ideal: 90)
            TableColumn(tr(vi: "Dung lượng", en: "Size")) { row in
                Text(VietnameseFormat.bytes(row.bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)
            TableColumn(tr(vi: "Lý do upload", en: "Cause")) { row in
                Text(HistoryText.origin(row.origin)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        }
    }

    private var footer: some View {
        HStack {
            if list.failed {
                Text(HistoryText.readFailed).font(.caption).foregroundStyle(.red)
            } else {
                Text(list.rows.isEmpty && !list.isLoading
                    ? tr(vi: "Không có file nào khớp.", en: "No files match.")
                    : tr(vi: "\(L10n.integer(list.rows.count)) dòng", en: L10n.plural(list.rows.count, one: "1 row", other: "\(L10n.integer(list.rows.count)) rows")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if list.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            if list.hasMore {
                Button(tr(vi: "Tải thêm", en: "Load more")) { Task { await list.loadMore(app: model) } }
                    .disabled(list.isLoading)
            }
        }
        .padding(8)
    }

    private func tint(_ outcome: TransferOutcome) -> Color {
        switch outcome {
        case .uploaded, .updated: .green
        case .failed: .red
        case .skipped: .orange
        case .cancelled: .secondary
        }
    }
}
