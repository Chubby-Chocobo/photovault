import PhotoVaultCore
import SwiftUI

/// Settings › Nội dung: the global ceilings of FR-05. A destination gets a kind of content only when
/// this tab and the destination's own rules both allow it (FR-72).
struct ContentTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(
            .info, title: tr(vi: "Trần toàn cục cho mọi đích", en: "Global limits for all destinations"),
            message: tr(vi: "Tắt ở đây thì không đích nào nhận loại đó, dù rule của đích đang bật. Bật thêm → xếp hàng các asset liên quan; tắt → chỉ huỷ phần còn chờ, không xoá gì ở đích.", en: "Turning a kind off here stops every destination from receiving it, even if the destination's own rule is on. Turning one on queues the related assets; turning one off only cancels what is still pending and deletes nothing at the destination."))
        SettingsSection(tr(vi: "Loại nội dung", en: "Content types")) {
            Toggle("Video", isOn: model.binding(\.includeVideos))
            Toggle(isOn: model.binding(\.includeEdited)) {
                labelWithDetail(tr(vi: "Bản chỉnh sửa", en: "Edited versions"), tr(vi: "Lưu cạnh bản gốc với hậu tố “(edited)”. Bản gốc không bao giờ bị ghi đè.", en: "Saved next to the original with the suffix “(edited)”. The original is never overwritten."))
            }
            Toggle(tr(vi: "Mọi khung burst", en: "All burst frames"), isOn: model.binding(\.includeAllBurstFrames))
            Toggle(isOn: model.binding(\.includeHidden)) {
                labelWithDetail("Album Hidden", tr(vi: "Vẫn được quét; chỉ không upload khi tắt.", en: "Still scanned; just not uploaded when off."))
            }
        }
        SettingsSection("Sidecar") {
            Toggle(isOn: model.binding(\.sidecarJsonEnabled)) {
                labelWithDetail("Sidecar JSON", tr(vi: "Metadata đầy đủ: ngày giờ, vị trí, album, máy ảnh.", en: "Full metadata: date and time, location, albums, camera."))
            }
            Toggle(isOn: model.binding(\.sidecarXmpEnabled)) {
                labelWithDetail("Sidecar XMP", tr(vi: "Favorite, caption, keyword, album cho Lightroom/digiKam.", en: "Favorite, caption, keywords and albums for Lightroom/digiKam."))
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
