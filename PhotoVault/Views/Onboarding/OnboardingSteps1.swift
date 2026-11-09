import PhotoVaultAppSupport
import SwiftUI

struct GoogleStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(
            title: "Đăng nhập Google",
            lead: "PhotoVault mở trình duyệt mặc định để bạn đăng nhập. Ứng dụng chỉ xin quyền tạo và đọc những file do chính nó tạo trên Drive của bạn.")
        SettingsSection("Quyền xin") {
            FormRow("Phạm vi") { Text("drive.file · openid · email").foregroundStyle(.secondary) }
            FormRow("Lưu đăng nhập") { Text("Chỉ trong Keychain của Mac").foregroundStyle(.secondary) }
        }
        switch model.google {
        case .none:
            Button("Đăng nhập bằng Google…") { model.startSignIn() }.buttonStyle(.borderedProminent)
        case .waiting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Đang chờ trình duyệt…")
                Button("Huỷ") { model.cancelSignIn() }
            }
        case .done:
            HStack {
                Label("Đã đăng nhập: \(model.identity?.email ?? "tài khoản Google")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Dùng tài khoản khác") { Task { await model.useAnotherAccount() } }
            }
        }
        if let error = model.signInError {
            Banner(.danger, title: "Không đăng nhập được", message: error)
        }
    }
}

struct PhotosStep: View {
    @Bindable var model: OnboardingModel
    @Environment(AppModel.self) private var app

    var body: some View {
        StepHeader(
            title: "Quyền truy cập Photos",
            lead: "PhotoVault đọc thư viện Photos để backup bản gốc và bản chỉnh sửa. Ứng dụng không sửa thư viện và không cần Full Disk Access.")
        switch model.photos {
        case .authorized:
            Banner(.success, title: "Đã có quyền đọc toàn bộ thư viện Photos.")
        case .notDetermined:
            Button("Cho phép truy cập Photos…") { Task { await model.requestPhotos() } }.buttonStyle(.borderedProminent)
        case .denied, .restricted, .limited:
            Banner(
                .danger, title: "PhotoVault chưa có quyền đọc Photos nên chưa thể chạy",
                message: "Mở System Settings › Privacy & Security › Photos, bật PhotoVault (quyền đọc toàn bộ thư viện, không phải “Giới hạn”) rồi quay lại đây. Mọi bước sync đều dừng cho tới khi có quyền.") {
                HStack {
                    Button("Mở System Settings") { app.openSystemSettings(.photosPrivacy) }
                    Button("Tôi đã bật, kiểm tra lại") { model.recheckPhotos() }
                }
            }
        }
    }
}

struct DriveRootStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(
            title: "Thư mục gốc trên Drive",
            lead: "Mọi file backup nằm trong thư mục này. PhotoVault chỉ thấy file do chính nó tạo.")
        RootChooser(roots: model.roots, canReuse: model.app.hardeningAvailable, reuseRootId: $model.reuseRootId, newName: $model.rootName)
        SettingsNote("Đặt ở My Drive. Đổi tên sau trong Settings không ảnh hưởng gì tới backup.")
        if let error = model.rootsError {
            Banner(.warning, title: "Chưa kiểm tra được thư mục cũ", message: error) {
                Button("Thử lại") { Task { await model.loadRoots() } }
            }
        }
    }
}

struct TimeZoneStep: View {
    @Bindable var model: OnboardingModel

    /// 23:30 UTC on 8 Nov 2026, the instant the mockup uses to show how the zone moves the date.
    private static let example = Date(timeIntervalSince1970: 1_794_180_600)

    var body: some View {
        StepHeader(
            title: "Múi giờ lưu trữ",
            lead: "Dùng để tính ngày, tên thư mục và tên file cho mọi ảnh. Múi giờ này cố định, không đổi theo nơi bạn đang ở.")
        SettingsSection("Archive timezone") {
            Picker("Archive timezone", selection: Binding(
                get: { model.timeZone.identifier },
                set: { id in if let zone = TimeZone(identifier: id) { model.timeZone = zone } })
            ) {
                ForEach(ArchiveTimeZoneText.options(including: .current), id: \.identifier) { zone in
                    Text(ArchiveTimeZoneText.label(zone) + (zone.identifier == TimeZone.current.identifier ? " — giờ của máy" : ""))
                        .tag(zone.identifier)
                }
            }
            .labelsHidden()
            FormRow("Ví dụ: ảnh chụp lúc 23:30 UTC ngày 08/11/2026") {
                Text(ArchiveTimeZoneText.filenameExample(at: Self.example, in: model.timeZone)).monospaced().textSelection(.enabled)
            }
        }
        SettingsNote("Đổi sau trong Settings chỉ áp dụng cho ảnh chưa được xếp chỗ.")
    }
}
