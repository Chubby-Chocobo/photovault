import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import SwiftUI

enum ImportProviderIcon {
    static func name(_ kind: SourceKind) -> String {
        switch kind {
        case .googleDrive, .dropbox: "icloud.and.arrow.down"
        case .localFolder, .photos: "folder"
        }
    }
}

struct ImportRunningRow: View {
    var item: ImportSnapshot
    var waitingReason: String?
    /// Signed in again; the resume waits for the engine.
    var signedInWaiting = false
    var onCancel: () -> Void
    var onSignInAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: ImportProviderIcon.name(item.kind)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(item.displayName).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if CloudImportText.needsSignIn(item), !signedInWaiting {
                    Button(tr(vi: "Đăng nhập lại", en: "Sign in again"), action: onSignInAgain).controlSize(.small)
                }
                Button(tr(vi: "Huỷ", en: "Cancel"), role: .destructive, action: onCancel).controlSize(.small)
            }
            Text(CloudImportText.providerLabel(kind: item.kind, account: item.account, syncedProvider: item.syncedProvider)).font(.caption).foregroundStyle(.secondary)
            ImportLocationLine(item: item)
            if CloudImportText.needsSignIn(item), item.account != nil, !signedInWaiting {
                Text(CloudImportText.wrongAccountNotice(expected: item.account))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if signedInWaiting {
                waitingLine(Image(systemName: "checkmark.circle.fill").foregroundStyle(.green), CloudImportText.signedInWaiting)
            } else if ImportQueue.isQueued(item) {
                waitingLine(ProgressView().controlSize(.mini), ImportProgressText.statusLabel(item))
            } else {
                Text(waitingReason ?? ImportProgressText.statusLabel(item)).font(.caption)
                    .foregroundStyle(item.status == .offline || waitingReason != nil || ImportProgressText.waitsForDisk(item) ? .orange : .secondary)
            }
            if !ImportQueue.isQueued(item), item.status != .offline || item.found > 0 {
                ProgressBar(fraction: ImportProgressText.fraction(item))
                    .accessibilityLabel(tr(vi: "Tiến độ nhập", en: "Import progress"))
            }
            let line = ImportProgressText.progressLine(item)
            if !line.isEmpty { Text(line).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
            let rest = [
                item.unsupported > 0 ? tr(vi: "\(VietnameseFormat.integer(item.unsupported)) bỏ qua", en: "\(VietnameseFormat.integer(item.unsupported)) skipped") : nil,
                item.failed > 0 ? tr(vi: "\(VietnameseFormat.integer(item.failed)) lỗi", en: "\(VietnameseFormat.integer(item.failed)) failed") : nil,
            ].compactMap { $0 }
            if !rest.isEmpty { Text(rest.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private func waitingLine(_ icon: some View, _ text: String) -> some View {
    HStack(spacing: 6) {
        icon
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

struct ImportFinishedRow: View {
    var item: ImportSnapshot
    var signedInWaiting = false
    var onSignInAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(item.status == .completed ? Color.green : Color.secondary).accessibilityHidden(true)
                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(ImportProgressText.statusLabel(item.status) + (item.finishedAt.map { " · " + RelativeTimeText.ago($0, now: Date()) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(CloudImportText.providerLabel(kind: item.kind, account: item.account, syncedProvider: item.syncedProvider)).font(.caption).foregroundStyle(.secondary)
            ImportLocationLine(item: item)
            Text(ImportProgressText.summaryLine(item)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if signedInWaiting {
                waitingLine(Image(systemName: "checkmark.circle.fill").foregroundStyle(.green), CloudImportText.signedInWaiting)
            } else if CloudImportText.needsSignIn(item) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tr(vi: "Cần đăng nhập lại để các ảnh còn chờ được backup. ", en: "Sign in again so the photos still waiting can be backed up. ")
                         + (item.account != nil ? CloudImportText.wrongAccountNotice(expected: item.account) : ""))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(tr(vi: "Đăng nhập lại", en: "Sign in again"), action: onSignInAgain).controlSize(.small)
                }
            }
            if let hint = CloudImportText.emptyImportNotice(item) {
                Text(hint).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: CloudImportText.needsSignIn(item) ? .contain : .combine)
    }
}
