import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

struct DiskCriticalCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.persistedSettings
        Banner(
            .danger, title: tr(vi: "Ổ Mac chỉ còn \(VietnameseFormat.bytes(model.macFreeBytes)) trống", en: "Only \(VietnameseFormat.bytes(model.macFreeBytes)) free on the Mac"),
            message: tr(
                vi: "Dưới ngưỡng nguy cấp \(settings.criticalWatermarkGB) GB nên PhotoVault đã dừng mọi export và huỷ export đang chạy. File đã export xong vẫn được upload. Tự chạy lại khi trống từ \(VietnameseFormat.gigabytes(MacDiskState.resumeBytes(settings: settings))) (kiểm tra mỗi 15 phút).",
                en: "Free space is below the critical limit of \(settings.criticalWatermarkGB) GB, so PhotoVault stopped all exports and cancelled the running ones. Files already exported are still uploaded. It restarts when \(VietnameseFormat.gigabytes(MacDiskState.resumeBytes(settings: settings))) is free (checked every 15 minutes).")) {
            HStack {
                Button(tr(vi: "Mở Dung lượng…", en: "Open Storage…")) { model.openSystemSettings(.storage) }
                Button(tr(vi: "Đổi ngưỡng…", en: "Change limit…")) { model.settingsTab = .advanced; model.open(.settings(.advanced)) }
            }
        }
    }
}

/// A database from 0.1.0 is not migrated: the owner starts over, and syncing is stopped until then.
struct OldLayoutCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(
            .danger, title: tr(vi: "Bản sao lưu này dùng bố cục thư mục cũ (0.1.0)", en: "This backup uses the old folder layout (0.1.0)"),
            message: tr(
                vi: "Bản 0.2.0 xếp ảnh theo từng ngày nên cần bắt đầu lại từ đầu. PhotoVault tạm dừng hẳn để không trộn hai kiểu thư mục. Ảnh đã backup không bị xoá hay di chuyển: hãy chuyển thư mục backup cũ ở Drive hoặc NAS vào Thùng rác, rồi bấm “Đặt lại từ đầu…” trong Cài đặt › Nâng cao và thiết lập với thư mục mới.",
                en: "Version 0.2.0 files photos by day, so it needs a fresh start. PhotoVault stays stopped so the two layouts are not mixed. Photos already backed up are not deleted or moved: move the old backup folder on Drive or the NAS to the Trash, then click “Start over…” in Settings › Advanced and set up with a new folder.")) {
            Button(tr(vi: "Mở Cài đặt › Nâng cao…", en: "Open Settings › Advanced…")) { model.open(.settings(.advanced)) }
        }
    }
}

struct OfflineCard: View {
    @Environment(AppModel.self) private var model
    var record: DestinationRecord

    var body: some View {
        Banner(
            .warning, title: tr(
                vi: "Không thấy “\(record.displayName)” từ \(RelativeTimeText.time(record.statusSince))",
                en: "Can’t find “\(record.displayName)” since \(RelativeTimeText.time(record.statusSince))"),
            message: tr(
                vi: "PhotoVault kiểm tra lại mỗi 5 phút và khi có ổ được mount; không tự mount SMB. File không được giữ lại chờ NAS, sẽ export lại khi NAS quay lại.",
                en: "PhotoVault checks again every 5 minutes and whenever a drive is mounted; it does not mount SMB itself. Files are not held back waiting for the NAS and will be exported again when it returns.")) {
            HStack {
                Button(tr(vi: "Kiểm tra lại", en: "Check again")) { model.syncNow() }
                Button(tr(vi: "Tạm dừng đích này", en: "Pause this destination")) { model.togglePause(record) }
            }
        }
    }
}

struct PhotosDeniedCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(
            .danger, title: tr(vi: "PhotoVault chưa có quyền đọc Photos", en: "PhotoVault can’t read Photos yet"),
            message: tr(
                vi: "Mở System Settings › Privacy & Security › Photos, bật PhotoVault. Mọi bước sync dừng cho tới khi có quyền.",
                en: "Open System Settings › Privacy & Security › Photos and turn on PhotoVault. All sync steps stay stopped until access is granted.")) {
            Button(tr(vi: "Mở System Settings", en: "Open System Settings")) { model.openSystemSettings(.photosPrivacy) }
        }
    }
}

struct SignInAgainCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(
            .danger, title: tr(vi: "Cần đăng nhập lại Google", en: "Sign in to Google again"),
            message: tr(
                vi: "Đích Drive tạm dừng cho tới khi bạn đăng nhập lại. Dữ liệu và lịch sử backup giữ nguyên.",
                en: "The Drive destination is paused until you sign in again. Your data and backup history are untouched.")) {
            Button(tr(vi: "Đăng nhập lại…", en: "Sign in again…")) { model.settingsTab = .general; model.open(.settings(.general)) }
        }
    }
}
