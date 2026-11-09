import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Adds a NAS or external folder: Test connection, own scope (FR-71), reuse of a folder that was a destination before (FR-74).
struct AddDestinationSheet: View {
    @Environment(AppModel.self) private var model
    @State var pending: PendingLocalDestination
    var onClose: () -> Void
    @State private var testing = false
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr(vi: "Thêm NAS hoặc ổ ngoài", en: "Add a NAS or external drive")).font(.title3.weight(.semibold))
            LocalDestinationForm(pending: $pending, testing: $testing)
            NoticeBanner()
            HStack {
                Spacer()
                Button(tr(vi: "Huỷ", en: "Cancel"), action: onClose).keyboardShortcut(.cancelAction)
                Button(pending.isReuse ? tr(vi: "Dùng lại và khôi phục", en: "Reuse and restore") : tr(vi: "Thêm", en: "Add")) {
                    Task {
                        adding = true
                        if await model.addLocalDestination(pending) { onClose() }
                        adding = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!pending.testPassed || adding || (pending.isReuse && !model.hardeningAvailable) || pending.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

/// The folder summary, Test connection, reuse prompt and scope of a pending destination (also used by onboarding).
struct LocalDestinationForm: View {
    @Environment(AppModel.self) private var model
    @Binding var pending: PendingLocalDestination
    @Binding var testing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(tr(vi: "Tên", en: "Name")) { TextField(tr(vi: "Tên đích", en: "Destination name"), text: $pending.name).textFieldStyle(.roundedBorder).frame(width: 260) }
            LabeledContent(tr(vi: "Thư mục", en: "Folder")) { Text(pending.url.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            HStack {
                Button("Test connection") {
                    Task {
                        testing = true
                        pending = await model.testConnection(pending)
                        testing = false
                    }
                }
                .disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                if pending.testPassed {
                    Label(tr(vi: "Ghi, đọc và xoá .photovault-test thành công", en: "Wrote, read and deleted .photovault-test successfully"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                    if let free = pending.freeBytes { Text(tr(vi: "Trống \(VietnameseFormat.bytes(free))", en: "\(VietnameseFormat.bytes(free)) free")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let marker = pending.existingMarker {
                Banner(
                    .info, title: tr(vi: "Thư mục này đã từng là đích PhotoVault", en: "This folder was a PhotoVault destination before"),
                    message: tr(
                        vi: "Có .photovault/destination.json (tạo \(marker.createdAt.formatted(.dateTime.day().month().year()))). Dùng lại thì PhotoVault khôi phục trạng thái từ thư mục trước khi ghi, không ghi trùng.",
                        en: "Has .photovault/destination.json (created \(marker.createdAt.formatted(.dateTime.day().month().year()))). If reused, PhotoVault restores state from the folder before writing, so nothing is written twice."))
                if !model.hardeningAvailable {
                    Text(tr(vi: "Dùng lại cần chức năng khôi phục, chưa khả dụng trong bản build này.", en: "Reuse needs the restore feature, which is not available in this build.")).font(.caption).foregroundStyle(.red)
                }
            }
            Text(tr(vi: "Phạm vi của đích này", en: "Scope of this destination")).font(.headline)
            ScopePicker(scope: $pending.scope, timeZone: model.archiveTimeZone)
            Text(tr(vi: "Nội dung cũ được export lại từ Photos theo giới hạn tốc độ. Rule chi tiết (category, RAW, sidecar…) chỉnh ở Settings › Đích.", en: "Older content is re-exported from Photos within the speed limit. Detailed rules (category, RAW, sidecar…) are set in Settings › Destinations."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
