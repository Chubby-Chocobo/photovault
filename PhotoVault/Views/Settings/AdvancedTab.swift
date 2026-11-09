import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Settings › Nâng cao: speed and power (8.5), Mac disk (FR-31), integrity and maintenance (FR-47, FR-76).
struct AdvancedTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRecovery = false

    var body: some View {
        SettingsSection(tr(vi: "Tốc độ & điện năng", en: "Speed and power")) {
            FormRow(tr(vi: "Tốc độ export khi backfill", en: "Export speed while backfilling")) {
                gigabyteField(model.binding(\.backfillGBPerHour), unit: tr(vi: "GB/giờ", en: "GB/hour"), label: tr(vi: "GB mỗi giờ", en: "GB per hour"))
            }
            Toggle(tr(vi: "Backfill chỉ khi cắm sạc", en: "Backfill only when plugged in"), isOn: model.binding(\.backfillOnlyOnACPower))
            Toggle(tr(vi: "Mọi upload chỉ khi cắm sạc", en: "All uploads only when plugged in"), isOn: model.binding(\.allUploadsOnlyOnACPower))
            Toggle(tr(vi: "Dừng khi mạng tính phí (hotspot)", en: "Pause on metered network (hotspot)"), isOn: model.binding(\.pauseOnExpensiveNetwork))
        }
        SettingsSection(tr(vi: "Dung lượng ổ Mac", en: "Mac disk space")) {
            FormRow(
                tr(vi: "Ngưỡng thấp (lowWatermark)", en: "Low threshold (lowWatermark)"),
                detail: tr(
                    vi: "Dưới mức này dừng backfill; chạy lại khi trống từ \(model.settings.lowWatermarkGB + 5) GB.",
                    en: "Backfill stops below this; it resumes when \(model.settings.lowWatermarkGB + 5) GB or more is free.")) {
                gigabyteField(model.binding(\.lowWatermarkGB), unit: "GB", label: "lowWatermark GB")
            }
            FormRow(tr(vi: "Ngưỡng nguy cấp (criticalWatermark)", en: "Critical threshold (criticalWatermark)"), detail: tr(vi: "Dưới mức này dừng mọi export.", en: "All exports stop below this.")) {
                gigabyteField(model.binding(\.criticalWatermarkGB), unit: "GB", label: "criticalWatermark GB")
            }
            FormRow(tr(vi: "Giới hạn staging (mềm)", en: "Staging limit (soft)")) {
                gigabyteField(model.binding(\.stagingSoftLimitGB), unit: "GB", label: "Staging GB")
            }
            ForEach(model.settingsIssues, id: \.self) { issue in
                Text(issue.message).font(.caption).foregroundStyle(.red).accessibilityAddTraits(.isStaticText)
            }
            Text(tr(vi: "Ổ Mac đang trống \(VietnameseFormat.bytes(model.macFreeBytes))", en: "Mac disk has \(VietnameseFormat.bytes(model.macFreeBytes)) free")).font(.caption).foregroundStyle(.secondary)
        }
        SettingsSection(tr(vi: "Toàn vẹn & bảo trì", en: "Integrity and maintenance")) {
            FormRow(tr(vi: "Kiểm tra toàn vẹn mỗi", en: "Check integrity every")) {
                HStack {
                    TextField("", value: model.binding(\.integrityCheckIntervalDays), format: .number)
                        .frame(width: 60).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(tr(vi: "Số ngày", en: "Number of days"))
                    Text(tr(vi: "ngày", en: "days"))
                }
            }
            FormRow(
                tr(vi: "Kiểm tra toàn vẹn", en: "Integrity check"),
                detail: model.lastIntegrityCheck.map { tr(vi: "Lần cuối ", en: "Last run ") + RelativeTimeText.ago($0, now: Date()) } ?? tr(vi: "Chưa kiểm tra lần nào", en: "Never checked")) {
                Button(tr(vi: "Kiểm tra ngay", en: "Check now")) { model.runIntegrityCheck() }.disabled(!model.hardeningAvailable)
            }
            FormRow(tr(vi: "Đối soát thư viện", en: "Reconcile library"), detail: tr(vi: "Liệt kê lại toàn bộ Photos để bắt thay đổi bị sót.", en: "Re-list all of Photos to catch missed changes.")) {
                Button(tr(vi: "Đối soát", en: "Reconcile")) { model.runReconciliation() }.disabled(!model.hardeningAvailable)
            }
            FormRow(tr(vi: "Thử lại job bị hoãn", en: "Retry deferred jobs"), detail: tr(vi: "Đưa job deferred về hàng chờ.", en: "Move deferred jobs back to the queue.")) {
                Button(tr(vi: "Thử lại", en: "Retry")) { model.retryDeferred() }.disabled(!model.hardeningAvailable)
            }
            FormRow(tr(vi: "Thử lại job bị bỏ qua", en: "Retry skipped jobs"), detail: tr(vi: "Đưa job skipped về hàng chờ.", en: "Move skipped jobs back to the queue.")) {
                Button(tr(vi: "Thử lại", en: "Retry")) { model.retrySkipped() }.disabled(!model.hardeningAvailable)
            }
            FormRow(tr(vi: "Khôi phục trạng thái từ đích", en: "Restore state from a destination"), detail: tr(vi: "Ghép lại file đã có ở đích vào cơ sở dữ liệu, không upload lại.", en: "Match files already at the destination back into the database, without uploading again.")) {
                Button(tr(vi: "Khôi phục giúp tôi…", en: "Restore for me…")) { confirmRecovery = true }.disabled(!model.hardeningAvailable || model.destinations.isEmpty)
            }
            if !model.hardeningAvailable {
                SettingsNote(tr(vi: "Một số thao tác bảo trì chưa khả dụng trong bản build này.", en: "Some maintenance actions are not available in this build."))
            }
            FormRow("Log") {
                Button(tr(vi: "Mở thư mục log", en: "Open log folder")) { model.revealLog() }
            }
        }
        .confirmationDialog(tr(vi: "Khôi phục trạng thái từ đích nào?", en: "Restore state from which destination?"), isPresented: $confirmRecovery) {
            ForEach(model.destinations, id: \.id) { record in
                Button(record.displayName) { model.startRecovery(record.id) }
            }
            Button(tr(vi: "Huỷ", en: "Cancel"), role: .cancel) {}
        } message: {
            Text(tr(vi: "Chỉ chạy khi scan đã hoàn tất. Đích tạm dừng (đang khôi phục) trong lúc đó.", en: "Runs only when the scan has finished. The destination is paused (restoring) in the meantime."))
        }
    }

    private func gigabyteField(_ value: Binding<Int>, unit: String, label: String) -> some View {
        HStack {
            TextField("", value: value, format: .number)
                .frame(width: 70).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
            Text(unit)
        }
    }
}
