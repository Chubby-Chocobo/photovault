import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

struct DiskCriticalCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.persistedSettings
        Banner(
            .danger, title: "Ổ Mac chỉ còn \(VietnameseFormat.bytes(model.macFreeBytes)) trống",
            message: "Dưới ngưỡng nguy cấp \(settings.criticalWatermarkGB) GB nên PhotoVault đã dừng mọi export và huỷ export đang chạy. File đã export xong vẫn được upload. Tự chạy lại khi trống từ \(VietnameseFormat.gigabytes(MacDiskState.resumeBytes(settings: settings))) (kiểm tra mỗi 15 phút).") {
            HStack {
                Button("Mở Dung lượng…") { model.openSystemSettings(.storage) }
                Button("Đổi ngưỡng…") { model.settingsTab = .advanced; model.open(.settings(.advanced)) }
            }
        }
    }
}

struct OfflineCard: View {
    @Environment(AppModel.self) private var model
    var record: DestinationRecord

    var body: some View {
        Banner(
            .warning, title: "Không thấy “\(record.displayName)” từ \(RelativeTimeText.time(record.statusSince))",
            message: "PhotoVault kiểm tra lại mỗi 5 phút và khi có ổ được mount; không tự mount SMB. File không được giữ lại chờ NAS, sẽ export lại khi NAS quay lại.") {
            HStack {
                Button("Kiểm tra lại") { model.syncNow() }
                Button("Tạm dừng đích này") { model.togglePause(record) }
            }
        }
    }
}

struct PhotosDeniedCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(
            .danger, title: "PhotoVault chưa có quyền đọc Photos",
            message: "Mở System Settings › Privacy & Security › Photos, bật PhotoVault. Mọi bước sync dừng cho tới khi có quyền.") {
            Button("Mở System Settings") { model.openSystemSettings(.photosPrivacy) }
        }
    }
}
