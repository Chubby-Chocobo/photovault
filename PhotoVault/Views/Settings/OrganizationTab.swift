import PhotoVaultAppSupport
import PhotoVaultEngine
import SwiftUI

/// Settings › Sắp xếp: day folders (spec 8.7), classification (FR-20), Drive views (FR-103), device groups (FR-104).
struct OrganizationTab: View {
    @Environment(AppModel.self) private var model
    @State private var preview: ResortPreview?
    @State private var confirmResort = false
    @State private var confirmRebuild = false
    @State private var newAlbum = ""
    @State private var counts: AppQueries.ViewCounts?

    private static let itemWarningThreshold = 400_000

    var body: some View {
        SettingsSection("Thư mục ngày") {
            FormRow("Tách thư mục ngày khi một ngày có hơn", detail: "Chỉ tính ảnh camera. Áp dụng cho ngày mới từ giờ.") {
                HStack {
                    TextField("", value: model.binding(\.dayFolderThreshold), format: .number)
                        .frame(width: 60).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Ngưỡng thư mục ngày")
                    Text("ảnh")
                }
            }
            issues(for: [.dayThresholdOutOfRange])
            FormRow(resortCaption) {
                Button("Sắp xếp lại…") { confirmResort = true }.disabled((preview?.files ?? 0) == 0)
            }
        }
        .task(id: model.persistedSettings.dayFolderThreshold) { preview = await model.resortPreview() }
        .confirmationDialog(resortTitle, isPresented: $confirmResort) {
            Button("Sắp xếp lại") { Task { await model.resortApply(); preview = await model.resortPreview() } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("PhotoVault sẽ chuyển \(VietnameseFormat.integer(preview?.files ?? 0)) file (bản gốc, bản chỉnh sửa, sidecar) của \(VietnameseFormat.integer(preview?.days ?? 0)) ngày vào thư mục ngày ở mọi đích. Thư mục ngày đã có giữ nguyên.")
        }

        SettingsSection("Phân loại") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Album app chat → “Saved”")
                Text("So khớp chính xác tên album (không phân biệt hoa thường).").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(model.settings.chatAppAlbumNames, id: \.self) { name in
                        HStack(spacing: 4) {
                            Text(name)
                            Button { removeAlbum(name) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Bỏ \(name)")
                        }
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
                HStack {
                    TextField("Tên album", text: $newAlbum).textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit(addAlbum)
                    Button("Thêm", action: addAlbum)
                }
            }
            Toggle(isOn: model.binding(\.photosWithoutCameraExifAreSaved)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ảnh thiếu EXIF máy ảnh → “Saved”")
                    Text("Ảnh scan có thể bị xếp vào Saved.").font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsNote("Đổi quy tắc phân loại chỉ áp dụng cho ảnh chưa được xếp chỗ.")
        }

        SettingsSection("View trên Drive") {
            Toggle("By device", isOn: model.binding(\.viewByDeviceEnabled))
            Toggle(isOn: model.binding(\.viewByPlaceEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("By place")
                    if !model.settings.placeNamesEnabled {
                        Text("Cần bật địa danh ở tab Địa danh & riêng tư").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!model.settings.placeNamesEnabled)
            Toggle("Favorites", isOn: model.binding(\.viewFavoritesEnabled))
            Divider()
            FormRow("Ước tính số item trên My Drive") {
                Text(VietnameseFormat.integer(estimatedItems))
                    .monospacedDigit().foregroundStyle(estimatedItems > Self.itemWarningThreshold ? Color.red : Color.primary)
            }
            if estimatedItems > Self.itemWarningThreshold {
                Banner(.warning, title: "Vượt ngưỡng cảnh báo \(VietnameseFormat.integer(Self.itemWarningThreshold)) item",
                       message: "Google có thể giới hạn số item trong My Drive; cân nhắc tắt bớt view.")
            }
            SettingsNote("Tắt view thì cây hiện có được giữ nguyên. Shortcut không tốn dung lượng.")
            FormRow("Đưa By device, By place và Favorites về đúng trạng thái, kể cả shortcut bạn đã xoá.") {
                Button("Dựng lại view…") { confirmRebuild = true }
            }
        }
        .task { counts = await model.viewCounts() }
        .confirmationDialog("Dựng lại view?", isPresented: $confirmRebuild) {
            Button("Dựng lại view") { Task { await model.rebuildViews() } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Tạo shortcut còn thiếu (kể cả shortcut bạn đã xoá), chuyển shortcut sai chỗ, cho shortcut thừa vào Thùng rác. File backup không bị đụng tới.")
        }

        DeviceGroupsSection()
    }

    private var resortTitle: String { "Sắp xếp lại theo ngưỡng \(model.persistedSettings.dayFolderThreshold) ảnh?" }

    private var resortCaption: String {
        guard let preview else { return "Đang tính…" }
        return preview.files > 0
            ? "Sắp xếp lại sẽ chuyển \(VietnameseFormat.integer(preview.files)) file của \(VietnameseFormat.integer(preview.days)) ngày vào thư mục ngày."
            : "Không có file nào cần chuyển. Thư mục ngày đã có không bị gộp ngược."
    }

    private var estimatedItems: Int {
        guard let counts else { return 0 }
        let settings = model.settings
        var total = counts.files + counts.folders
        if settings.viewByDeviceEnabled { total += counts.device }
        if settings.viewByPlaceEnabled && settings.placeNamesEnabled { total += counts.place }
        if settings.viewFavoritesEnabled { total += counts.favorites }
        return total
    }

    private func addAlbum() {
        var albums = model.settings.chatAppAlbumNames
        guard SettingsValidator.addingAlbum(newAlbum, to: &albums) else { return }
        model.settings.chatAppAlbumNames = albums
        newAlbum = ""
        model.scheduleCommit()
    }

    private func removeAlbum(_ name: String) {
        model.settings.chatAppAlbumNames.removeAll { $0 == name }
        model.scheduleCommit()
    }

    @ViewBuilder
    private func issues(for wanted: [SettingsIssue]) -> some View {
        ForEach(model.settingsIssues.filter(wanted.contains), id: \.self) { issue in
            Text(issue.message).font(.caption).foregroundStyle(.red)
        }
    }
}
