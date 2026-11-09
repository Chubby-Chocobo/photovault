import PhotoVaultAppSupport
import SwiftUI
import PhotoVaultCore

struct GoogleStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(
            title: tr(vi: "Đăng nhập Google", en: "Sign in to Google"),
            lead: tr(
                vi: "PhotoVault mở trình duyệt mặc định để bạn đăng nhập. Ứng dụng chỉ xin quyền tạo và đọc những file do chính nó tạo trên Drive của bạn.",
                en: "PhotoVault opens your default browser for you to sign in. The app only asks to create and read the files it created itself on your Drive."))
        SettingsSection(tr(vi: "Quyền xin", en: "Permissions requested")) {
            FormRow(tr(vi: "Phạm vi", en: "Scopes")) { Text("drive.file · openid · email").foregroundStyle(.secondary) }
            FormRow(tr(vi: "Lưu đăng nhập", en: "Sign-in stored")) { Text(tr(vi: "Chỉ trong Keychain của Mac", en: "Only in the Mac’s Keychain")).foregroundStyle(.secondary) }
        }
        switch model.google {
        case .none:
            Button(tr(vi: "Đăng nhập bằng Google…", en: "Sign in with Google…")) { model.startSignIn() }.buttonStyle(.borderedProminent)
        case .waiting:
            HStack {
                ProgressView().controlSize(.small)
                Text(tr(vi: "Đang chờ trình duyệt…", en: "Waiting for the browser…"))
                Button(tr(vi: "Huỷ", en: "Cancel")) { model.cancelSignIn() }
            }
        case .done:
            HStack {
                Label(
                    tr(vi: "Đã đăng nhập: \(model.identity?.email ?? "tài khoản Google")",
                       en: "Signed in: \(model.identity?.email ?? "Google account")"),
                    systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(tr(vi: "Dùng tài khoản khác", en: "Use another account")) { Task { await model.useAnotherAccount() } }
            }
        }
        if let error = model.signInError {
            Banner(.danger, title: tr(vi: "Không đăng nhập được", en: "Could not sign in"), message: error)
        }
    }
}

struct PhotosStep: View {
    @Bindable var model: OnboardingModel
    @Environment(AppModel.self) private var app

    var body: some View {
        StepHeader(
            title: tr(vi: "Quyền truy cập Photos", en: "Photos access"),
            lead: tr(
                vi: "PhotoVault đọc thư viện Photos để backup bản gốc và bản chỉnh sửa. Ứng dụng không sửa thư viện và không cần Full Disk Access.",
                en: "PhotoVault reads the Photos library to back up originals and edited versions. The app never changes the library and does not need Full Disk Access."))
        switch model.photos {
        case .authorized:
            Banner(.success, title: tr(vi: "Đã có quyền đọc toàn bộ thư viện Photos.", en: "Full access to the Photos library is granted."))
        case .notDetermined:
            Button(tr(vi: "Cho phép truy cập Photos…", en: "Allow access to Photos…")) { Task { await model.requestPhotos() } }.buttonStyle(.borderedProminent)
        case .denied, .restricted, .limited:
            Banner(
                .danger, title: tr(vi: "PhotoVault chưa có quyền đọc Photos nên chưa thể chạy", en: "PhotoVault can’t read Photos yet, so it can’t run"),
                message: tr(
                    vi: "Mở System Settings › Privacy & Security › Photos, bật PhotoVault (quyền đọc toàn bộ thư viện, không phải “Giới hạn”) rồi quay lại đây. Mọi bước sync đều dừng cho tới khi có quyền.",
                    en: "Open System Settings › Privacy & Security › Photos and turn on PhotoVault (access to the whole library, not “Limited”), then come back here. All sync steps stay stopped until access is granted.")) {
                HStack {
                    Button(tr(vi: "Mở System Settings", en: "Open System Settings")) { app.openSystemSettings(.photosPrivacy) }
                    Button(tr(vi: "Tôi đã bật, kiểm tra lại", en: "I turned it on, check again")) { model.recheckPhotos() }
                }
            }
        }
    }
}

struct DriveRootStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(
            title: tr(vi: "Thư mục gốc trên Drive", en: "Root folder on Drive"),
            lead: tr(
                vi: "Mọi file backup nằm trong thư mục này. PhotoVault chỉ thấy file do chính nó tạo.",
                en: "All backup files go in this folder. PhotoVault only sees the files it created itself."))
        RootChooser(roots: model.roots, canReuse: model.app.hardeningAvailable, reuseRootId: $model.reuseRootId, newName: $model.rootName)
        SettingsNote(tr(
            vi: "Đặt ở My Drive. Đổi tên sau trong Settings không ảnh hưởng gì tới backup.",
            en: "It is placed in My Drive. Renaming it later in Settings does not affect the backup."))
        if let error = model.rootsError {
            Banner(.warning, title: tr(vi: "Chưa kiểm tra được thư mục cũ", en: "Could not check for old folders"), message: error) {
                Button(tr(vi: "Thử lại", en: "Try again")) { Task { await model.loadRoots() } }
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
            title: tr(vi: "Múi giờ lưu trữ", en: "Archive time zone"),
            lead: tr(
                vi: "Dùng để tính ngày, tên thư mục và tên file cho mọi ảnh. Múi giờ này cố định, không đổi theo nơi bạn đang ở.",
                en: "Used to work out the day, folder name and file name of every photo. This time zone is fixed and does not change with where you are."))
        SettingsSection(tr(vi: "Archive timezone", en: "Archive time zone")) {
            Picker(tr(vi: "Archive timezone", en: "Archive time zone"), selection: Binding(
                get: { model.timeZone.identifier },
                set: { id in if let zone = TimeZone(identifier: id) { model.timeZone = zone } })
            ) {
                ForEach(ArchiveTimeZoneText.options(including: .current), id: \.identifier) { zone in
                    Text(ArchiveTimeZoneText.label(zone) + (zone.identifier == TimeZone.current.identifier ? tr(vi: " — giờ của máy", en: " — this Mac’s time") : ""))
                        .tag(zone.identifier)
                }
            }
            .labelsHidden()
            FormRow(tr(vi: "Ví dụ: ảnh chụp lúc 23:30 UTC ngày 08/11/2026", en: "Example: a photo taken at 23:30 UTC on 08/11/2026")) {
                Text(ArchiveTimeZoneText.filenameExample(at: Self.example, in: model.timeZone)).monospaced().textSelection(.enabled)
            }
        }
        SettingsNote(tr(
            vi: "Đổi sau trong Settings chỉ áp dụng cho ảnh chưa được xếp chỗ.",
            en: "Changing it later in Settings only applies to photos not yet placed."))
    }
}
