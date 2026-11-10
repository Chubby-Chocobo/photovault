import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import SwiftUI

enum ImportProviderIcon {
    static func name(_ item: ImportSnapshot) -> String { ImportProviderSymbol.name(kind: item.kind, synced: item.syncedProvider) }
}

/// The list box of the import sections: rows with a divider between them, inside a thin border.
struct ImportListBox<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
    }
}

/// A row of the import lists: padding, and a divider above every row but the first.
struct ImportListRow<Content: View>: View {
    var first: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Divider() }
            content().padding(.horizontal, 10).padding(.vertical, 8)
        }
    }
}

struct ImportRunningRow: View {
    var row: ImportQueueRow
    var item: ImportSnapshot { row.item }
    var waitingReason: String?
    /// Signed in again; the resume waits for the engine.
    var signedInWaiting = false
    var cancelling = false
    /// Place in line and reason of a queued entry; the reason also explains a signed-in-again wait.
    var queueWait: (title: String, reason: String)?
    var waitReason = ""
    var onCancel: () -> Void
    var onSignInAgain: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(row.number)").font(.caption.weight(.semibold)).monospacedDigit()
                .frame(width: 22, height: 22).background(Circle().fill(Color.secondary.opacity(0.18)))
                .accessibilityLabel(tr(vi: "Số thứ tự \(row.number)", en: "Number \(row.number)"))
            Image(systemName: ImportProviderIcon.name(item)).frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
            details
            Button(action: onCancel) { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(cancelling)
                .help(tr(vi: "Huỷ lần nhập này", en: "Cancel this import"))
                .accessibilityLabel(tr(vi: "Huỷ lần nhập này", en: "Cancel this import"))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.displayName).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(row.badge).font(.caption2.weight(.semibold)).foregroundStyle(row.isQueued ? Color.secondary : Color.accentColor)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill((row.isQueued ? Color.secondary : Color.accentColor).opacity(0.15)))
            }
            Text(CloudImportText.providerLabel(kind: item.kind, account: item.account, syncedProvider: item.syncedProvider)).font(.caption).foregroundStyle(.secondary)
            ImportLocationLine(item: item)
            if CloudImportText.needsSignIn(item), item.account != nil, !signedInWaiting {
                Text(CloudImportText.wrongAccountNotice(expected: item.account))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if cancelling {
                waitingLine(ProgressView().controlSize(.mini), ImportQueue.cancellingText)
                Text(waitReason).font(.caption2).foregroundStyle(.tertiary)
            } else if signedInWaiting {
                waitingLine(Image(systemName: "checkmark.circle.fill").foregroundStyle(.green), CloudImportText.signedInWaiting)
                Text(waitReason).font(.caption2).foregroundStyle(.tertiary)
            } else if ImportQueue.isQueued(item) {
                waitingLine(ProgressView().controlSize(.mini), queueWait?.title ?? ImportProgressText.statusLabel(item))
                if let reason = queueWait?.reason { Text(reason).font(.caption2).foregroundStyle(.tertiary) }
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
            if CloudImportText.needsSignIn(item), !signedInWaiting {
                Button(tr(vi: "Đăng nhập lại", en: "Sign in again"), action: onSignInAgain).controlSize(.small)
            }
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
    var waitReason = ""
    var onSignInAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: ImportProviderIcon.name(item)).foregroundStyle(.secondary).accessibilityHidden(true)
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
                Text(waitReason).font(.caption2).foregroundStyle(.tertiary)
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
