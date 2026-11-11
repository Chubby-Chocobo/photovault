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
        if let summary = ImportQueueLayout.popoverSummary(model.queueRows) {
            let item = summary.head.item
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ImportProgressText.menuTitle(folderName: item.displayName)).font(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle).help(ImportLocationText.tooltip(item.location) ?? "")
                    Spacer(minLength: 6)
                    Button { confirming.toggle() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(tr(vi: "Huỷ lần nhập này", en: "Cancel this import"))
                        .accessibilityLabel(tr(vi: "Huỷ lần nhập này", en: "Cancel this import"))
                }
                let provider = CloudImportText.providerLabel(kind: item.kind, account: item.account, syncedProvider: item.syncedProvider)
                Text(provider).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(provider)
                progressSlot(item)
                let _ = model.transferNow
                let line = CardActivityText.importJob(item.id, transfers: model.transfers, now: Date())
                CardActivityLine(line: line, isBusy: line != nil)
                // The status line keeps its slot while the import is queued or cancelling.
                let status = ImportQueue.isQueued(item) || model.isCancelling(item) ? "" : statusText(item)
                FittedLineText(line: FittedLine(lead: status)).font(.caption)
                    .foregroundStyle(item.status == .offline || waitingReason(item) != nil ? .orange : .secondary)
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
                if let waiting = summary.waitingLine {
                    Text(waiting).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(waiting)
                }
            }
        }
    }

    /// The progress bar, or the two lines that say why the import waits, in one slot of the same height.
    private func progressSlot(_ item: ImportSnapshot) -> some View {
        ZStack(alignment: .leading) {
            // The wait block's two lines, unseen, give the slot its height whichever of the two is shown.
            waitBlock(title: " ", reason: " ", isBusy: false).hidden().accessibilityHidden(true)
            if model.isCancelling(item) {
                waitBlock(title: ImportQueue.cancellingText, reason: model.engineWaitReason, isBusy: true)
            } else if let wait = model.queueWait(for: item) {
                waitBlock(title: wait.title, reason: wait.reason, isBusy: true)
            } else {
                ProgressBar(fraction: ImportProgressText.fraction(item))
                    .accessibilityLabel(tr(vi: "Tiến độ nhập", en: "Import progress"))
            }
        }
    }

    private func waitBlock(title: String, reason: String, isBusy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                SlotSpinner(isBusy: isBusy)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(title)
            }
            Text(reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail).help(reason)
        }
    }

    private func waitingReason(_ item: ImportSnapshot) -> String? {
        ImportProgressText.waitingForPhotos(item, photosAllowsReading: model.photosAuthorization.allowsReading)
    }

    private func statusText(_ item: ImportSnapshot) -> String {
        if let reason = waitingReason(item) { return reason }
        let line = ImportProgressText.progressLine(item)
        return line.isEmpty || item.status == .offline || ImportProgressText.waitsForDisk(item) ? ImportProgressText.statusLabel(item) : line
    }
}
