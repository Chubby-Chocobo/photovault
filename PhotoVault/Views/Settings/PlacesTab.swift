import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Settings › Địa danh & riêng tư (FR-81..85, FR-106).
struct PlacesTab: View {
    @Environment(AppModel.self) private var model
    @State private var progress: AppQueries.GeocodeProgress?
    @State private var confirmRefresh = false

    private static let countryCodes = ["VN", "JP", "US", "TH", "SG", "KR", "CN", "TW", "FR", "DE", "GB", "AU", "CA", "IT", "ES"]

    private var codes: [String] {
        let current = model.settings.homeCountryCode
        return Self.countryCodes.contains(current) ? Self.countryCodes : [current] + Self.countryCodes
    }

    private func cellCount(_ n: Int) -> String {
        L10n.plural(n, one: "1 cell", other: "\(VietnameseFormat.integer(n)) cells")
    }

    /// A folder name as it appears on destinations, so the same in both interface languages.
    private static let homeExample = "2026-11-07 Hà Nội" // l10n: verbatim

    var body: some View {
        SettingsSection(tr(vi: "Địa danh", en: "Places")) {
            Toggle(isOn: model.binding(\.placeNamesEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(vi: "Đặt tên địa danh cho thư mục ngày", en: "Add place names to day folders"))
                    Text(tr(vi: "Ví dụ “\(Self.homeExample)”; ở nước ngoài “2026-10-02 Kyoto (京都市), Japan”: tên nước bằng tiếng Anh, tên nơi bằng tiếng Anh kèm tên bản địa.", en: "For example “\(Self.homeExample)”; abroad “2026-10-02 Kyoto (京都市), Japan”: the country in English, the place in English with its native name."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(tr(vi: "Quốc gia nhà", en: "Home country"), detail: tr(vi: "Không thêm tên nước cho nơi trong nước nhà.", en: "Don't add the country name for places in the home country.")) {
                Picker(tr(vi: "Quốc gia nhà", en: "Home country"), selection: model.binding(\.homeCountryCode)) {
                    ForEach(codes, id: \.self) { code in
                        Text(Locale(identifier: L10n.language.rawValue).localizedString(forRegionCode: code) ?? code).tag(code)
                    }
                }
                .labelsHidden().frame(width: 160)
            }
            .disabled(!model.settings.placeNamesEnabled)
            SettingsNote(tr(vi: "Chỉ đặt tên khi ngày đã kết thúc ít nhất 6 giờ. Ngày có ảnh ở nhiều tỉnh/thành được tách thành một thư mục cho mỗi nơi.", en: "Names are added once the day ended at least 6 hours ago. A day with photos in several provinces gets one folder per place."))
        }
        Banner(
            .info, title: tr(vi: "Quyền riêng tư", en: "Privacy"),
            message: tr(vi: "Để tra tên địa danh, PhotoVault gửi toạ độ đã làm tròn khoảng 1 km tới dịch vụ bản đồ của Apple. Không gửi ảnh, tên file hay thông tin nào khác. Tắt mục trên thì không gửi gì, thư mục ngày không có địa danh và view By place không được tạo.", en: "To look up place names, PhotoVault sends coordinates rounded to about 1 km to Apple's map service. No photos, file names or other information are sent. With the option above off, nothing is sent, day folders have no place names and the By place view is not created."))
        SettingsSection(tr(vi: "Tiến độ tra địa danh", en: "Place lookup progress")) {
            if let progress, progress.totalCells > 0 {
                Text(tr(
                    vi: "Đã tra \(VietnameseFormat.integer(progress.resolvedCells)) / \(VietnameseFormat.integer(progress.totalCells)) ô (~1 km)",
                    en: "Looked up \(VietnameseFormat.integer(progress.resolvedCells)) of \(cellCount(progress.totalCells)) (~1 km)"))
                ProgressBar(fraction: ProgressText.fraction(done: progress.resolvedCells, total: progress.totalCells))
            } else {
                Text(tr(vi: "Chưa có ô toạ độ nào cần tra.", en: "No coordinate cells to look up yet.")).foregroundStyle(.secondary)
            }
            SettingsNote(tr(vi: "Tối đa 20 request/phút, chạy nền nhiều ngày, không chặn upload.", en: "At most 20 requests per minute, runs in the background for days, doesn't block uploads."))
            FormRow(tr(vi: "Xoá cache địa danh và tra lại từ đầu", en: "Clear the place cache and look everything up again")) {
                Button(tr(vi: "Làm mới địa danh…", en: "Refresh place names…")) { confirmRefresh = true }.disabled(!model.settings.placeNamesEnabled)
            }
        }
        .task(id: model.snapshot?.updatedAt) { progress = await model.geocodeProgress() }
        .confirmationDialog(tr(vi: "Làm mới địa danh?", en: "Refresh place names?"), isPresented: $confirmRefresh) {
            Button(tr(vi: "Làm mới địa danh", en: "Refresh place names")) { Task { await model.refreshPlaceNames() } }
            Button(tr(vi: "Huỷ", en: "Cancel"), role: .cancel) {}
        } message: {
            let cells = progress?.totalCells ?? 0
            let hours = Double(cells) * 2 / 20.0 / 60.0
            Text(tr(
                vi: "Xoá cache địa danh và tra lại \(VietnameseFormat.integer(cells)) ô, khoảng \(VietnameseFormat.decimal(hours, fractionDigits: 1)) giờ ở 20 request/phút. Tên thư mục ngày và view By place được cập nhật khi tra xong.",
                en: "Clears the place cache and looks up \(cellCount(cells)) again, about \(VietnameseFormat.decimal(hours, fractionDigits: 1)) hours at 20 requests per minute. Day folder names and the By place view are updated when it finishes."))
        }
    }
}
