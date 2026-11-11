import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// The files of one import in path order, paged.
struct ImportItemTable: View {
    @Environment(AppModel.self) private var model
    var list: ImportItemListModel
    @Binding var selection: ImportItemRow.ID?

    var body: some View {
        VStack(spacing: 0) {
            Table(list.rows, selection: $selection) {
                TableColumn(tr(vi: "File", en: "File")) { row in
                    Text(row.relativePath).lineLimit(1).truncationMode(.head)
                }
                .width(min: 160, ideal: 280)
                TableColumn(tr(vi: "Kết quả", en: "Result")) { row in
                    Text(HistoryText.importState(row.state)).foregroundStyle(tint(row.state))
                }
                .width(min: 80, ideal: 110)
                TableColumn(tr(vi: "Dung lượng", en: "Size")) { row in
                    Text(VietnameseFormat.bytes(row.sizeBytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 70)
            }
            Divider()
            HStack {
                Text(tr(vi: "\(L10n.integer(list.rows.count)) file", en: L10n.plural(list.rows.count, one: "1 file", other: "\(L10n.integer(list.rows.count)) files")))
                    .font(.caption).foregroundStyle(.secondary)
                if list.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                if list.hasMore {
                    Button(tr(vi: "Tải thêm", en: "Load more")) { Task { await list.loadMore(app: model) } }
                        .disabled(list.isLoading)
                }
            }
            .padding(8)
        }
    }

    private func tint(_ state: ImportItemState) -> Color {
        switch state {
        case .imported: .green
        case .failed: .red
        case .unsupported, .cancelled: .orange
        case .duplicate, .pending: .secondary
        }
    }
}
