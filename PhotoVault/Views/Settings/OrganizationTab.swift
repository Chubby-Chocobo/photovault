import PhotoVaultAppSupport
import PhotoVaultCore
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
        SettingsSection(tr(vi: "Thư mục ngày", en: "Day folders")) {
            FormRow(tr(vi: "Tách thư mục ngày khi một ngày có hơn", en: "Split the day folder when a day has more than"), detail: tr(vi: "Chỉ tính ảnh camera. Áp dụng cho ngày mới từ giờ.", en: "Counts camera photos only. Applies to new days from now on.")) {
                HStack {
                    TextField("", value: model.binding(\.dayFolderThreshold), format: .number)
                        .frame(width: 60).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(tr(vi: "Ngưỡng thư mục ngày", en: "Day folder threshold"))
                    Text(tr(vi: "ảnh", en: "photos"))
                }
            }
            issues(for: [.dayThresholdOutOfRange])
            FormRow(resortCaption) {
                Button(tr(vi: "Sắp xếp lại…", en: "Re-sort…")) { confirmResort = true }.disabled((preview?.files ?? 0) == 0)
            }
        }
        .task(id: model.persistedSettings.dayFolderThreshold) { preview = await model.resortPreview() }
        .confirmationDialog(resortTitle, isPresented: $confirmResort) {
            Button(tr(vi: "Sắp xếp lại", en: "Re-sort")) { Task { await model.resortApply(); preview = await model.resortPreview() } }
            Button(tr(vi: "Huỷ", en: "Cancel"), role: .cancel) {}
        } message: {
            Text(tr(
                vi: "PhotoVault sẽ chuyển \(VietnameseFormat.integer(preview?.files ?? 0)) file (bản gốc, bản chỉnh sửa, sidecar) của \(VietnameseFormat.integer(preview?.days ?? 0)) ngày vào thư mục ngày ở mọi đích. Thư mục ngày đã có giữ nguyên.",
                en: "PhotoVault will move \(fileCount(preview?.files ?? 0)) (originals, edited versions, sidecars) from \(dayCount(preview?.days ?? 0)) into day folders on every destination. Existing day folders are left as they are."))
        }

        SettingsSection(tr(vi: "Phân loại", en: "Classification")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(vi: "Album app chat → “Saved”", en: "Chat app albums → “Saved”"))
                Text(tr(vi: "So khớp chính xác tên album (không phân biệt hoa thường).", en: "Matches the album name exactly (case-insensitive).")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(model.settings.chatAppAlbumNames, id: \.self) { name in
                        HStack(spacing: 4) {
                            Text(name)
                            Button { removeAlbum(name) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel(tr(vi: "Bỏ \(name)", en: "Remove \(name)"))
                        }
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
                HStack {
                    TextField(tr(vi: "Tên album", en: "Album name"), text: $newAlbum).textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit(addAlbum)
                    Button(tr(vi: "Thêm", en: "Add"), action: addAlbum)
                }
            }
            Toggle(isOn: model.binding(\.photosWithoutCameraExifAreSaved)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(vi: "Ảnh thiếu EXIF máy ảnh → “Saved”", en: "Photos without camera EXIF → “Saved”"))
                    Text(tr(vi: "Ảnh scan có thể bị xếp vào Saved.", en: "Scanned photos may end up in Saved.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsNote(tr(vi: "Đổi quy tắc phân loại chỉ áp dụng cho ảnh chưa được xếp chỗ.", en: "A new classification rule only applies to photos not yet placed."))
        }

        SettingsSection(tr(vi: "View trên Drive", en: "Views on Drive")) {
            Toggle("By device", isOn: model.binding(\.viewByDeviceEnabled))
            Toggle(isOn: model.binding(\.viewByPlaceEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("By place")
                    if !model.settings.placeNamesEnabled {
                        Text(tr(vi: "Cần bật địa danh ở tab Địa danh & riêng tư", en: "Turn on place names in the Places & privacy tab")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!model.settings.placeNamesEnabled)
            Toggle("Favorites", isOn: model.binding(\.viewFavoritesEnabled))
            Divider()
            FormRow(tr(vi: "Ước tính số item trên My Drive", en: "Estimated items in My Drive")) {
                Text(VietnameseFormat.integer(estimatedItems))
                    .monospacedDigit().foregroundStyle(estimatedItems > Self.itemWarningThreshold ? Color.red : Color.primary)
            }
            if estimatedItems > Self.itemWarningThreshold {
                Banner(.warning, title: tr(vi: "Vượt ngưỡng cảnh báo \(VietnameseFormat.integer(Self.itemWarningThreshold)) item",
                                           en: "Over the warning threshold of \(VietnameseFormat.integer(Self.itemWarningThreshold)) items"),
                       message: tr(vi: "Google có thể giới hạn số item trong My Drive; cân nhắc tắt bớt view.", en: "Google may limit the number of items in My Drive; consider turning off some views."))
            }
            SettingsNote(tr(vi: "Tắt view thì cây hiện có được giữ nguyên. Shortcut không tốn dung lượng.", en: "Turning a view off leaves the existing tree as it is. Shortcuts use no storage."))
            FormRow(tr(vi: "Đưa By device, By place và Favorites về đúng trạng thái, kể cả shortcut bạn đã xoá.", en: "Bring By device, By place and Favorites back to the right state, including shortcuts you deleted.")) {
                Button(tr(vi: "Dựng lại view…", en: "Rebuild views…")) { confirmRebuild = true }
            }
        }
        .task { counts = await model.viewCounts() }
        .confirmationDialog(tr(vi: "Dựng lại view?", en: "Rebuild views?"), isPresented: $confirmRebuild) {
            Button(tr(vi: "Dựng lại view", en: "Rebuild views")) { Task { await model.rebuildViews() } }
            Button(tr(vi: "Huỷ", en: "Cancel"), role: .cancel) {}
        } message: {
            Text(tr(vi: "Tạo shortcut còn thiếu (kể cả shortcut bạn đã xoá), chuyển shortcut sai chỗ, cho shortcut thừa vào Thùng rác. File backup không bị đụng tới.", en: "Creates missing shortcuts (including ones you deleted), moves misplaced shortcuts and puts extra shortcuts in the Trash. Backup files are not touched."))
        }

        DeviceGroupsSection()
    }

    private var resortTitle: String {
        let threshold = model.persistedSettings.dayFolderThreshold
        return tr(
            vi: "Sắp xếp lại theo ngưỡng \(threshold) ảnh?",
            en: "Re-sort with a threshold of \(L10n.plural(threshold, one: "1 photo", other: "\(threshold) photos"))?")
    }

    private func fileCount(_ n: Int) -> String {
        L10n.plural(n, one: "1 file", other: "\(VietnameseFormat.integer(n)) files")
    }

    private func dayCount(_ n: Int) -> String {
        L10n.plural(n, one: "1 day", other: "\(VietnameseFormat.integer(n)) days")
    }

    private var resortCaption: String {
        guard let preview else { return tr(vi: "Đang tính…", en: "Calculating…") }
        return preview.files > 0
            ? tr(
                vi: "Sắp xếp lại sẽ chuyển \(VietnameseFormat.integer(preview.files)) file của \(VietnameseFormat.integer(preview.days)) ngày vào thư mục ngày.",
                en: "Re-sorting will move \(fileCount(preview.files)) from \(dayCount(preview.days)) into day folders.")
            : tr(
                vi: "Không có file nào cần chuyển. Thư mục ngày đã có không bị gộp ngược.",
                en: "No files need to move. Existing day folders are not merged back.")
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
