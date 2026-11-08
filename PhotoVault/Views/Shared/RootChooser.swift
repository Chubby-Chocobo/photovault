import PhotoVaultAppSupport
import PhotoVaultDrive
import SwiftUI

/// Reuse an earlier PhotoVault root or create a new one (FR-01 step 3, FR-08, FR-51).
struct RootChooser: View {
    var roots: [RemoteItemSummary]
    var canReuse: Bool
    @Binding var reuseRootId: String?
    @Binding var newName: String

    struct RemoteItemSummary: Identifiable, Equatable {
        var id: String
        var name: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Tên thư mục") {
                TextField("Camera Uploads", text: $newName)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .disabled(reuseRootId != nil)
            }
            if let issue = RootNameValidator.validate(newName), reuseRootId == nil {
                Text(issue.message).font(.caption).foregroundStyle(.red)
            }
            if !roots.isEmpty {
                Banner(
                    .info,
                    title: roots.count == 1
                        ? "Tìm thấy thư mục “\(roots[0].name)” do PhotoVault tạo trước đây"
                        : "Tìm thấy \(roots.count) thư mục do PhotoVault tạo trước đây",
                    message: "Bạn muốn dùng lại hay tạo thư mục mới?") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(roots) { root in
                            optionRow(
                                selected: reuseRootId == root.id, title: "Dùng lại “\(root.name)”",
                                detail: "PhotoVault khôi phục trạng thái từ Drive trước khi upload, nên file đã có sẽ không bị upload trùng.",
                                enabled: canReuse
                            ) { reuseRootId = root.id }
                        }
                        optionRow(
                            selected: reuseRootId == nil, title: "Tạo thư mục mới",
                            detail: "Thư mục cũ giữ nguyên, không bị xoá hay sửa.", enabled: true
                        ) { reuseRootId = nil }
                        if !canReuse {
                            Text("Dùng lại thư mục cũ cần chức năng khôi phục, chưa khả dụng trong bản build này.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func optionRow(selected: Bool, title: String, detail: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
