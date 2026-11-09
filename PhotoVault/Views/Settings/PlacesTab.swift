import PhotoVaultAppSupport
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

    var body: some View {
        SettingsSection("Địa danh") {
            Toggle(isOn: model.binding(\.placeNamesEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đặt tên địa danh cho thư mục ngày")
                    Text("Ví dụ “2026-11-07 Đà Lạt”, hoặc “2026-10-02 Kyoto, Nhật Bản” khi ở nước ngoài.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow("Ngôn ngữ tên địa danh") {
                Picker("Ngôn ngữ", selection: model.binding(\.placeNameLanguage)) {
                    Text("Tiếng Việt").tag("vi")
                    Text("English").tag("en")
                }
                .labelsHidden().frame(width: 160)
            }
            .disabled(!model.settings.placeNamesEnabled)
            FormRow("Quốc gia nhà", detail: "Không thêm tên nước cho nơi trong nước nhà.") {
                Picker("Quốc gia nhà", selection: model.binding(\.homeCountryCode)) {
                    ForEach(codes, id: \.self) { code in
                        Text(Locale(identifier: "vi").localizedString(forRegionCode: code) ?? code).tag(code)
                    }
                }
                .labelsHidden().frame(width: 160)
            }
            .disabled(!model.settings.placeNamesEnabled)
            SettingsNote("Chỉ đặt tên khi ngày đã kết thúc ít nhất 6 giờ và mọi ảnh có GPS cùng một tỉnh. Đổi ngôn ngữ thì đổi tên lại thư mục.")
        }
        Banner(
            .info, title: "Quyền riêng tư",
            message: "Để tra tên địa danh, PhotoVault gửi toạ độ đã làm tròn khoảng 1 km tới dịch vụ bản đồ của Apple. Không gửi ảnh, tên file hay thông tin nào khác. Tắt mục trên thì không gửi gì, thư mục ngày không có địa danh và view By place không được tạo.")
        SettingsSection("Tiến độ tra địa danh") {
            if let progress, progress.totalCells > 0 {
                Text("Đã tra \(VietnameseFormat.integer(progress.resolvedCells)) / \(VietnameseFormat.integer(progress.totalCells)) ô (~1 km)")
                ProgressBar(fraction: ProgressText.fraction(done: progress.resolvedCells, total: progress.totalCells))
            } else {
                Text("Chưa có ô toạ độ nào cần tra.").foregroundStyle(.secondary)
            }
            SettingsNote("Tối đa 20 request/phút, chạy nền nhiều ngày, không chặn upload.")
            FormRow("Xoá cache địa danh và tra lại từ đầu") {
                Button("Làm mới địa danh…") { confirmRefresh = true }.disabled(!model.settings.placeNamesEnabled)
            }
        }
        .task(id: model.snapshot?.updatedAt) { progress = await model.geocodeProgress() }
        .confirmationDialog("Làm mới địa danh?", isPresented: $confirmRefresh) {
            Button("Làm mới địa danh") { Task { await model.refreshPlaceNames() } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            let cells = progress?.totalCells ?? 0
            let hours = Double(cells) / 20.0 / 60.0
            Text("Xoá cache địa danh và tra lại \(VietnameseFormat.integer(cells)) ô, khoảng \(VietnameseFormat.decimal(hours, fractionDigits: 1)) giờ ở 20 request/phút. Tên thư mục ngày và view By place được cập nhật khi tra xong.")
        }
    }
}
