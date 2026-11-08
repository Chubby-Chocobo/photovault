import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

struct SyncModeStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(title: "Backup từ đâu?", lead: "Áp dụng cho Google Drive. NAS và ổ ngoài có phạm vi riêng.")
        ScopePicker(scope: $model.scope, timeZone: model.timeZone)
        SettingsNote("PhotoVault chỉ đếm số asset, không ước tính dung lượng. Đổi sau trong Settings: mở rộng thì xếp hàng thêm; thu hẹp chỉ huỷ phần chưa upload, không xoá gì ở đích.")
    }
}

struct NotificationsStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(
            title: "Thông báo",
            lead: "PhotoVault chạy nền trên menu bar; thông báo là cách nó báo bạn khi backup gặp vấn đề.")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(NotificationKind.allCases, id: \.self) { kind in
                Label(kind.summary, systemImage: "bell").labelStyle(.titleAndIcon)
            }
        }
        SettingsNote("Mỗi loại × mỗi đích tối đa 1 lần / 12 giờ.")
        switch model.notifications {
        case .notAsked: Button("Cho phép thông báo…") { Task { await model.requestNotifications() } }.buttonStyle(.borderedProminent)
        case .granted: Banner(.success, title: "Đã bật thông báo.")
        case .denied:
            Banner(.warning, title: "Thông báo đang tắt", message: "Bạn vẫn dùng được PhotoVault; bật lại trong System Settings › Notifications khi cần.") {
                Button("Mở System Settings") { model.app.openSystemSettings(.notifications) }
            }
        }
    }
}

struct NasStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(
            title: "Thêm NAS hoặc ổ ngoài (tuỳ chọn)",
            lead: "Mount NAS trong Finder trước; PhotoVault không tự mount SMB. Có thể thêm hoặc bỏ đích sau trong Settings.")
        if model.nas != nil {
            LocalDestinationForm(
                pending: Binding(get: { model.nas ?? placeholder }, set: { model.nas = $0 }),
                testing: Binding(get: { model.nasTesting }, set: { model.nasTesting = $0 }))
            Button("Chọn thư mục khác…") { Task { await model.chooseNas() } }
        } else {
            Button("Chọn thư mục…") { Task { await model.chooseNas() } }.buttonStyle(.borderedProminent)
            Text("Chưa chọn").foregroundStyle(.secondary)
        }
    }

    private var placeholder: PendingLocalDestination {
        PendingLocalDestination(destinationId: .local(), url: URL(fileURLWithPath: "/"), bookmark: Data(), name: "")
    }
}

struct SummaryStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepHeader(title: "Tóm tắt", lead: "Kiểm tra lại trước khi bắt đầu.")
        SettingsSection("Sẽ backup") {
            FormRow("Asset sẽ backup lên Drive") {
                Text(model.libraryCount.map { "\(VietnameseFormat.integer($0)) asset" } ?? "Đang đếm…").monospacedDigit()
            }
            FormRow("Google Drive · \(rootDisplayName)" + (model.reusing ? " (dùng lại)" : "")) {
                Text(model.driveFreeBytes.map { "Trống \(VietnameseFormat.bytes($0))" } ?? "—").foregroundStyle(.secondary)
            }
            if let nas = model.nas {
                FormRow("\(nas.name) · \(nas.url.path)") {
                    Text(nas.freeBytes.map { "Trống \(VietnameseFormat.bytes($0))" } ?? "—").foregroundStyle(.secondary)
                }
            }
            FormRow("Ổ Mac") {
                Text("Trống \(VietnameseFormat.bytes(model.app.macFreeBytes))")
                    .foregroundStyle(model.bytesToFree != nil ? Color.red : Color.primary)
            }
        }
        SettingsNote("Không có ước tính tổng dung lượng sẽ upload; PhotoVault chỉ biết số asset.")
        if let needed = model.bytesToFree {
            let low = model.app.persistedSettings.lowWatermarkGB
            Banner(
                .warning, title: "Cần giải phóng \(VietnameseFormat.gigabytes(needed)) trên ổ Mac",
                message: "Ổ Mac còn \(VietnameseFormat.bytes(model.app.macFreeBytes)), dưới ngưỡng backfill \(low) GB. Bạn vẫn có thể bắt đầu: ảnh mới vẫn được backup, còn backfill chờ tới khi ổ trống từ \(low + 5) GB.")
        } else {
            Banner(.success, title: "Ổ Mac đủ chỗ để backfill.",
                   message: "Tốc độ export tối đa \(model.app.persistedSettings.backfillGBPerHour) GB/giờ, chỉ khi cắm sạc.")
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
            title: "Sẵn sàng",
            lead: "Bấm Bắt đầu để PhotoVault chốt mốc thời gian, quét thư viện, rồi mới upload.")
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
        if let problem = model.startError {
            Banner(.danger, title: "Chưa thể bắt đầu", message: problem)
        }
        if let failure = app.firstStart?.failure {
            Banner(.danger, title: "Không bắt đầu được", message: failure) {
                Button("Thử lại") { Task { await model.start() } }
            }
        }
        if app.firstStart?.finished == true {
            Banner(.success, title: "PhotoVault đang chạy trên menu bar.", message: "Có thể đóng cửa sổ này.")
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
            let total = model.libraryCount.map { " / \(VietnameseFormat.integer($0)) asset" } ?? ""
            return "Đang quét metadata\(total) · không export file nào"
        case .restore:
            let matched = app.firstStart?.matchedFiles ?? 0
            return matched > 0 ? "Đã ghép \(VietnameseFormat.integer(matched)) file có sẵn · \(phase.detail)" : phase.detail
        default:
            return phase.detail
        }
    }
}
