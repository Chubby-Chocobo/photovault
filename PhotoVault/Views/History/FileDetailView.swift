import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultStore
import SwiftUI

/// The file a detail pane shows: a row of a transfer list or a file of an import.
enum HistoryFile: Equatable {
    case event(TransferEventRow)
    case importItem(ImportItemRow)

    /// The asset whose uploads the pane lists: the file itself, or for a duplicate the backed-up file it matched.
    var assetKey: AssetKey? {
        switch self {
        case .event(let row): row.assetKey
        case .importItem(let item): item.state == .imported || item.state == .duplicate ? item.assetKey : nil
        }
    }
}

/// Where one file stands at every destination, why it did not go up, its last check, and what the owner can do:
/// retry it, show it in Finder or open it on Drive.
struct FileDetailView: View {
    @Environment(AppModel.self) private var model
    var file: HistoryFile
    @State private var statuses: [FileDestinationStatus] = []
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if failed { Text(HistoryText.readFailed).font(.callout).foregroundStyle(.red) }
                if !statuses.isEmpty {
                    Divider()
                    Text(tr(vi: "Trên từng đích", en: "At each destination")).font(.subheadline.weight(.semibold))
                    ForEach(statuses) { status in destinationRow(status) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .task(id: file) { await load() }
    }

    @ViewBuilder private var header: some View {
        switch file {
        case .event(let row):
            Text(row.fileName).font(.headline).lineLimit(3)
            line(tr(vi: "Kết quả", en: "Result"), HistoryText.outcome(row.outcome) + " · " + HistoryText.time(row.at, approximate: row.approximate))
            line(tr(vi: "Lý do upload", en: "Cause"), HistoryText.origin(row.origin))
            if let captured = row.capturedAt { line(tr(vi: "Ngày chụp", en: "Taken"), RelativeTimeText.dateTime(captured)) }
            line(tr(vi: "Dung lượng", en: "Size"), VietnameseFormat.bytes(row.bytes))
            if let reason = HistoryReasonText.upload(reason: row.reason, detail: row.detail) { line(tr(vi: "Lý do", en: "Reason"), reason) }
            if let note = HistoryText.deletionNote(row) {
                Label(note, systemImage: HistoryText.keptAfterDeletion(row) ? "trash" : "minus.circle").font(.callout)
            }
            if row.approximate { Text(HistoryText.approximateNote).font(.caption).foregroundStyle(.secondary) }
        case .importItem(let item):
            Text(item.relativePath).font(.headline).lineLimit(4)
            line(tr(vi: "Kết quả", en: "Result"), HistoryText.importState(item.state))
            line(tr(vi: "Dung lượng", en: "Size"), VietnameseFormat.bytes(item.sizeBytes))
            if item.state == .duplicate {
                Text(HistoryReasonText.duplicate(of: item.duplicateOfName, capturedAt: item.duplicateOfCapturedAt)).font(.callout)
            } else if let reason = HistoryReasonText.importItem(state: item.state, reason: item.reason) {
                line(tr(vi: "Lý do", en: "Reason"), reason)
            }
            if item.state == .failed { Text(HistoryReasonText.reimportHint).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func destinationRow(_ status: FileDestinationStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HistoryText.destination(status.destinationId, names: model.destinationNames)).font(.callout.weight(.medium))
            Text(HistoryText.status(status)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if status.state == .deferred || status.state == .skipped, let key = file.assetKey {
                    Button(tr(vi: "Thử lại", en: "Retry")) {
                        Task {
                            await model.retryHistoryFiles([JobIdentity(destinationId: status.destinationId, assetKey: key, resType: status.resType)])
                            await load()
                        }
                    }
                }
                if status.state == .done, let remoteId = status.remoteId {
                    let drive = status.destinationId == .googleDrive
                    Button(drive ? tr(vi: "Mở trên Drive", en: "Open on Drive") : tr(vi: "Hiện trong Finder", en: "Show in Finder")) {
                        model.revealBackedUpFile(destination: status.destinationId, remoteId: remoteId)
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        guard let key = file.assetKey else {
            statuses = []
            failed = false
            return
        }
        do {
            statuses = try await model.historyRead { db in try HistoryRepository.statuses(db, assetKey: key) } ?? []
            failed = false
        } catch is CancellationError {
        } catch {
            statuses = []
            failed = true
        }
    }
}
