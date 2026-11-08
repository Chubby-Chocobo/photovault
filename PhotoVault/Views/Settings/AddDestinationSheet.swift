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
            Text("Thêm NAS hoặc ổ ngoài").font(.title3.weight(.semibold))
            LocalDestinationForm(pending: $pending, testing: $testing)
            NoticeBanner()
            HStack {
                Spacer()
                Button("Huỷ", action: onClose).keyboardShortcut(.cancelAction)
                Button(pending.isReuse ? "Dùng lại và khôi phục" : "Thêm") {
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
            LabeledContent("Tên") { TextField("Tên đích", text: $pending.name).textFieldStyle(.roundedBorder).frame(width: 260) }
            LabeledContent("Thư mục") { Text(pending.url.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
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
                    Label("Ghi, đọc và xoá .photovault-test thành công", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                    if let free = pending.freeBytes { Text("Trống \(VietnameseFormat.bytes(free))").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let marker = pending.existingMarker {
                Banner(
                    .info, title: "Thư mục này đã từng là đích PhotoVault",
                    message: "Có .photovault/destination.json (tạo \(marker.createdAt.formatted(.dateTime.day().month().year()))). Dùng lại thì PhotoVault khôi phục trạng thái từ thư mục trước khi ghi, không ghi trùng.")
                if !model.hardeningAvailable {
                    Text("Dùng lại cần chức năng khôi phục, chưa khả dụng trong bản build này.").font(.caption).foregroundStyle(.red)
                }
            }
            Text("Phạm vi của đích này").font(.headline)
            ScopePicker(scope: $pending.scope, timeZone: model.archiveTimeZone)
            Text("Nội dung cũ được export lại từ Photos theo giới hạn tốc độ. Rule chi tiết (category, RAW, sidecar…) chỉnh ở Settings › Đích.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
