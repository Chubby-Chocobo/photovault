import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

struct SyncModeStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(
            title: tr(vi: "Backup từ đâu?", en: "Back up from where?"),
            lead: tr(vi: "Áp dụng cho Google Drive. NAS và ổ ngoài có phạm vi riêng.", en: "Applies to Google Drive. A NAS and external drives have their own scope."))
        ScopePicker(scope: $model.scope, timeZone: model.timeZone)
        SettingsNote(tr(
            vi: "PhotoVault chỉ đếm số asset, không ước tính dung lượng. Đổi sau trong Settings: mở rộng thì xếp hàng thêm; thu hẹp chỉ huỷ phần chưa upload, không xoá gì ở đích.",
            en: "PhotoVault only counts assets and does not estimate size. If you change it later in Settings, widening queues more; narrowing only cancels what is not uploaded yet and deletes nothing at the destination."))
    }
}

struct NotificationsStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(
            title: tr(vi: "Thông báo", en: "Notifications"),
            lead: tr(
                vi: "PhotoVault chạy nền trên menu bar; thông báo là cách nó báo bạn khi backup gặp vấn đề.",
                en: "PhotoVault runs in the background in the menu bar; notifications are how it tells you when a backup has a problem."))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(NotificationKind.allCases, id: \.self) { kind in
                Label(kind.summary, systemImage: "bell").labelStyle(.titleAndIcon)
            }
        }
        SettingsNote(tr(vi: "Mỗi loại × mỗi đích tối đa 1 lần / 12 giờ.", en: "At most once per 12 hours for each kind × destination."))
        switch model.notifications {
        case .notAsked: Button(tr(vi: "Cho phép thông báo…", en: "Allow notifications…")) { Task { await model.requestNotifications() } }.buttonStyle(.borderedProminent)
        case .granted: Banner(.success, title: tr(vi: "Đã bật thông báo.", en: "Notifications are on."))
        case .denied:
            Banner(
                .warning, title: tr(vi: "Thông báo đang tắt", en: "Notifications are off"),
                message: tr(
                    vi: "Bạn vẫn dùng được PhotoVault; bật lại trong System Settings › Notifications khi cần.",
                    en: "You can still use PhotoVault; turn them back on in System Settings › Notifications when needed.")
            ) {
                Button(tr(vi: "Mở System Settings", en: "Open System Settings")) { model.app.openSystemSettings(.notifications) }
            }
        }
    }
}

struct NasStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(
            title: tr(vi: "Thêm NAS hoặc ổ ngoài (tuỳ chọn)", en: "Add a NAS or external drive (optional)"),
            lead: tr(
                vi: "Mount NAS trong Finder trước; PhotoVault không tự mount SMB. Có thể thêm hoặc bỏ đích sau trong Settings.",
                en: "Mount the NAS in Finder first; PhotoVault does not mount SMB itself. You can add or remove destinations later in Settings."))
        if model.nas != nil {
            LocalDestinationForm(
                pending: Binding(get: { model.nas ?? placeholder }, set: { model.nas = $0 }),
                testing: Binding(get: { model.nasTesting }, set: { model.nasTesting = $0 }))
            Button(tr(vi: "Chọn thư mục khác…", en: "Choose another folder…")) { Task { await model.chooseNas() } }
        } else {
            Button(tr(vi: "Chọn thư mục…", en: "Choose a folder…")) { Task { await model.chooseNas() } }.buttonStyle(.borderedProminent)
            Text(tr(vi: "Chưa chọn", en: "Nothing chosen")).foregroundStyle(.secondary)
        }
    }

    private var placeholder: PendingLocalDestination {
        PendingLocalDestination(destinationId: .local(), url: URL(fileURLWithPath: "/"), bookmark: Data(), name: "")
    }
}

struct SummaryStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(title: tr(vi: "Tóm tắt", en: "Summary"), lead: tr(vi: "Kiểm tra lại trước khi bắt đầu.", en: "Review before you start."))
        SettingsSection(tr(vi: "Sẽ backup", en: "Will back up")) {
            FormRow(tr(vi: "Asset sẽ backup lên Drive", en: "Assets to back up to Drive")) {
                Text(model.libraryCount.map { tr(vi: "\(VietnameseFormat.integer($0)) asset", en: L10n.plural($0, one: "1 asset", other: "\(VietnameseFormat.integer($0)) assets")) }
                    ?? tr(vi: "Đang đếm…", en: "Counting…")).monospacedDigit()
            }
            FormRow("Google Drive · \(rootDisplayName)" + (model.reusing ? tr(vi: " (dùng lại)", en: " (reused)") : "")) {
                Text(model.driveFreeBytes.map { tr(vi: "Trống \(VietnameseFormat.bytes($0))", en: "\(VietnameseFormat.bytes($0)) free") } ?? "—").foregroundStyle(.secondary)
            }
            if let nas = model.nas {
                FormRow("\(nas.name) · \(nas.url.path)") {
                    Text(nas.freeBytes.map { tr(vi: "Trống \(VietnameseFormat.bytes($0))", en: "\(VietnameseFormat.bytes($0)) free") } ?? "—").foregroundStyle(.secondary)
                }
            }
            FormRow(tr(vi: "Ổ Mac", en: "Mac drive")) {
                Text(tr(vi: "Trống \(VietnameseFormat.bytes(model.app.macFreeBytes))", en: "\(VietnameseFormat.bytes(model.app.macFreeBytes)) free"))
                    .foregroundStyle(model.bytesToFree != nil ? Color.red : Color.primary)
            }
        }
        SettingsNote(tr(
            vi: "Không có ước tính tổng dung lượng sẽ upload; PhotoVault chỉ biết số asset.",
            en: "There is no estimate of the total size to upload; PhotoVault only knows the number of assets."))
        if let needed = model.bytesToFree {
            let low = model.app.persistedSettings.lowWatermarkGB
            Banner(
                .warning,
                title: tr(
                    vi: "Cần giải phóng \(VietnameseFormat.gigabytes(needed)) trên ổ Mac",
                    en: "Free up \(VietnameseFormat.gigabytes(needed)) on the Mac drive"),
                message: tr(
                    vi: "Ổ Mac còn \(VietnameseFormat.bytes(model.app.macFreeBytes)), dưới ngưỡng backfill \(low) GB. Bạn vẫn có thể bắt đầu: ảnh mới vẫn được backup, còn backfill chờ tới khi ổ trống từ \(low + 5) GB.",
                    en: "The Mac drive has \(VietnameseFormat.bytes(model.app.macFreeBytes)) left, below the backfill limit of \(low) GB. You can still start: new photos are backed up, and backfill waits until \(low + 5) GB is free."))
        } else {
            Banner(
                .success, title: tr(vi: "Ổ Mac đủ chỗ để backfill.", en: "The Mac drive has enough room for backfill."),
                message: tr(
                    vi: "Tốc độ export tối đa \(model.app.persistedSettings.backfillGBPerHour) GB/giờ, chỉ khi cắm sạc.",
                    en: "Export runs at up to \(model.app.persistedSettings.backfillGBPerHour) GB/hour, only while charging."))
        }
    }

    private var rootDisplayName: String {
        switch model.rootChoice {
        case .createNew(let name): name
        case .reuse(_, let name): name
        }
    }
}

struct StartStep: View {
    @Bindable var model: OnboardingModel
    @Environment(AppModel.self) private var app

    var body: some View {
        StepHeader(
            title: tr(vi: "Sẵn sàng", en: "Ready"),
            lead: tr(
                vi: "Bấm Bắt đầu để PhotoVault chốt mốc thời gian, quét thư viện, rồi mới upload.",
                en: "Click Start and PhotoVault will fix a starting point in time, scan the library, then upload."))
        let phases = app.firstStart?.phases ?? OnboardingPhase.sequence(reusingExistingDestination: model.reusing)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                HStack(alignment: .top, spacing: 10) {
                    icon(for: index)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.title)
                        Text(detail(for: phase, index: index)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        Toggle(tr(vi: "Mở PhotoVault khi đăng nhập", en: "Open PhotoVault at login"), isOn: $model.launchAtLogin)
            .disabled(app.firstStart != nil)
        Text(tr(vi: "Có thể đổi sau trong Cài đặt › Chung.", en: "You can change this later in Settings › General."))
            .font(.caption).foregroundStyle(.secondary)
        if let problem = model.startError {
            Banner(.danger, title: tr(vi: "Chưa thể bắt đầu", en: "Can’t start yet"), message: problem)
        }
        if let failure = app.firstStart?.failure {
            Banner(.danger, title: tr(vi: "Không bắt đầu được", en: "Could not start"), message: failure) {
                Button(tr(vi: "Thử lại", en: "Try again")) { Task { await model.start() } }
            }
        }
        if app.firstStart?.finished == true {
            Banner(
                .success, title: tr(vi: "PhotoVault đang chạy trên menu bar.", en: "PhotoVault is running in the menu bar."),
                message: tr(vi: "Có thể đóng cửa sổ này.", en: "You can close this window."))
        }
    }

    @ViewBuilder
    private func icon(for index: Int) -> some View {
        let state = app.firstStart
        if let state, state.finished || index < state.current {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let state, index == state.current, state.isRunning {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func detail(for phase: OnboardingPhase, index: Int) -> String {
        switch phase {
        case .scan where app.firstStart?.current == index:
            let total = model.libraryCount.map { count in
                tr(vi: " / \(VietnameseFormat.integer(count)) asset",
                   en: " / \(L10n.plural(count, one: "1 asset", other: "\(VietnameseFormat.integer(count)) assets"))")
            } ?? ""
            return tr(vi: "Đang quét metadata\(total) · không export file nào", en: "Scanning metadata\(total) · no files exported")
        case .restore:
            let matched = app.firstStart?.matchedFiles ?? 0
            return matched > 0
                ? tr(
                    vi: "Đã ghép \(VietnameseFormat.integer(matched)) file có sẵn · \(phase.detail)",
                    en: "Matched \(L10n.plural(matched, one: "1 existing file", other: "\(VietnameseFormat.integer(matched)) existing files")) · \(phase.detail)")
                : phase.detail
        default:
            return phase.detail
        }
    }
}
