import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import SwiftUI

/// "Đang nhập" card of the menu bar: only while an import has not finished. The newest import is
/// shown; the others are counted.
struct ImportsCard: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        let running = model.runningImports
        if let item = running.first {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ImportProgressText.menuTitle(folderName: item.displayName)).font(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button { confirming.toggle() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(tr(vi: "Huỷ lần nhập này", en: "Cancel this import"))
                        .accessibilityLabel(tr(vi: "Huỷ lần nhập này", en: "Cancel this import"))
                }
                ProgressBar(fraction: ImportProgressText.fraction(item))
                    .accessibilityLabel(tr(vi: "Tiến độ nhập", en: "Import progress"))
                Text(statusText(item)).font(.caption).monospacedDigit().foregroundStyle(item.status == .offline || waitingReason(item) != nil ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if confirming {
                    HStack {
                        Text(tr(vi: "Huỷ nhập? File đã upload vẫn giữ.", en: "Cancel the import? Uploaded files stay.")).font(.caption)
                        Spacer(minLength: 4)
                        Button(tr(vi: "Huỷ nhập", en: "Cancel import"), role: .destructive) {
                            model.cancelImport(item.id)
                            confirming = false
                        }
                        Button(tr(vi: "Giữ", en: "Keep")) { confirming = false }
                    }
                    .controlSize(.small)
                }
                if let more = ImportProgressText.moreImports(running.count - 1) {
                    Text(more).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func waitingReason(_ item: ImportSnapshot) -> String? {
        ImportProgressText.waitingForPhotos(item, photosAllowsReading: model.photosAuthorization.allowsReading)
    }

    private func statusText(_ item: ImportSnapshot) -> String {
        if let reason = waitingReason(item) { return reason }
        let line = ImportProgressText.progressLine(item)
        return line.isEmpty || item.status == .offline ? ImportProgressText.statusLabel(item.status) : line
    }
}
