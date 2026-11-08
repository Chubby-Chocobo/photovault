import SwiftUI

/// Settings › Nội dung: the global ceilings of FR-05. A destination gets a kind of content only when
/// this tab and the destination's own rules both allow it (FR-72).
struct ContentTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(
            .info, title: "Trần toàn cục cho mọi đích",
            message: "Tắt ở đây thì không đích nào nhận loại đó, dù rule của đích đang bật. Bật thêm → xếp hàng các asset liên quan; tắt → chỉ huỷ phần còn chờ, không xoá gì ở đích.")
        SettingsSection("Loại nội dung") {
            Toggle("Video", isOn: model.binding(\.includeVideos))
            Toggle(isOn: model.binding(\.includeEdited)) {
                labelWithDetail("Bản chỉnh sửa", "Lưu cạnh bản gốc với hậu tố “(edited)”. Bản gốc không bao giờ bị ghi đè.")
            }
            Toggle("Mọi khung burst", isOn: model.binding(\.includeAllBurstFrames))
            Toggle(isOn: model.binding(\.includeHidden)) {
                labelWithDetail("Album Hidden", "Vẫn được quét; chỉ không upload khi tắt.")
            }
        }
        SettingsSection("Sidecar") {
            Toggle(isOn: model.binding(\.sidecarJsonEnabled)) {
                labelWithDetail("Sidecar JSON", "Metadata đầy đủ: ngày giờ, vị trí, album, máy ảnh.")
            }
            Toggle(isOn: model.binding(\.sidecarXmpEnabled)) {
                labelWithDetail("Sidecar XMP", "Favorite, caption, keyword, album cho Lightroom/digiKam.")
            }
        }
    }

    private func labelWithDetail(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
