import PhotoVaultAppSupport
import PhotoVaultDrive
import SwiftUI
import PhotoVaultCore

/// Reuse an earlier PhotoVault root or create a new one (FR-01 step 3, FR-08, FR-51).
struct RootChooser: View {
    var roots: [RemoteItemSummary]
    var canReuse: Bool
    @Binding var reuseRootId: String?
    @Binding var newName: String

    struct RemoteItemSummary: Identifiable, Equatable {
        var id: String
        var name: String
        /// Holds a 0.1.0 backup (year folders): not offered for reuse.
        var isLegacy = false
    }

    private var reusable: [RemoteItemSummary] { roots.filter { !$0.isLegacy } }
    private var legacy: [RemoteItemSummary] { roots.filter(\.isLegacy) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(tr(vi: "Tên thư mục", en: "Folder name")) {
                TextField("PhotoVault", text: $newName)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .disabled(reuseRootId != nil)
            }
            if let issue = RootNameValidator.validate(newName), reuseRootId == nil {
                Text(issue.message).font(.caption).foregroundStyle(.red)
            }
            if !legacy.isEmpty { OldBackupBanner(names: legacy.map(\.name)) }
            if !reusable.isEmpty {
                let roots = reusable
                Banner(
                    .info,
                    title: roots.count == 1
                        ? tr(
                            vi: "Tìm thấy thư mục “\(roots[0].name)” do PhotoVault tạo trước đây",
                            en: "Found the folder “\(roots[0].name)” that PhotoVault created earlier")
                        : tr(
                            vi: "Tìm thấy \(roots.count) thư mục do PhotoVault tạo trước đây",
                            en: "Found \(roots.count) folders that PhotoVault created earlier"),
                    message: tr(vi: "Bạn muốn dùng lại hay tạo thư mục mới?", en: "Do you want to reuse one or create a new folder?")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(roots) { root in
                            optionRow(
                                selected: reuseRootId == root.id, title: tr(vi: "Dùng lại “\(root.name)”", en: "Reuse “\(root.name)”"),
                                detail: tr(
                                    vi: "PhotoVault khôi phục trạng thái từ Drive trước khi upload, nên file đã có sẽ không bị upload trùng.",
                                    en: "PhotoVault recovers its state from Drive before uploading, so files already there are not uploaded twice."),
                                enabled: canReuse
                            ) { reuseRootId = root.id }
                        }
                        optionRow(
                            selected: reuseRootId == nil, title: tr(vi: "Tạo thư mục mới", en: "Create a new folder"),
                            detail: tr(vi: "Thư mục cũ giữ nguyên, không bị xoá hay sửa.", en: "The old folder stays as it is, not deleted or changed."), enabled: true
                        ) { reuseRootId = nil }
                        if !canReuse {
                            Text(tr(
                                vi: "Dùng lại thư mục cũ cần chức năng khôi phục, chưa khả dụng trong bản build này.",
                                en: "Reusing an old folder needs recovery, which is not available in this build."))
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

/// A folder from 0.1.0 is not offered for reuse: its year folders do not fit the day layout.
struct OldBackupBanner: View {
    var names: [String]

    var body: some View {
        Banner(
            .warning,
            title: names.count == 1
                ? tr(vi: "Thư mục “\(names[0])” là bản sao lưu của PhotoVault 0.1.0", en: "The folder “\(names[0])” is a PhotoVault 0.1.0 backup")
                : tr(vi: "\(names.count) thư mục là bản sao lưu của PhotoVault 0.1.0", en: "\(names.count) folders are PhotoVault 0.1.0 backups"),
            message: tr(
                vi: "Bản này xếp ảnh theo từng ngày nên không dùng lại được thư mục cũ. Ảnh trong đó không bị xoá hay sửa: hãy chuyển thư mục vào Thùng rác trong Google Drive hoặc Finder, hoặc tạo thư mục mới với tên khác.",
                en: "This version files photos by day, so the old folder can’t be reused. Nothing in it is deleted or changed: move the folder to the Trash in Google Drive or Finder, or create a new folder with a different name."))
    }
}
