import PhotoVaultAppSupport
import SwiftUI

/// Settings › Nâng cao: speed and power (8.5), Mac disk (FR-31), integrity and maintenance (FR-47, FR-76).
struct AdvancedTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRecovery = false

    var body: some View {
        SettingsSection("Tốc độ & điện năng") {
            FormRow("Tốc độ export khi backfill") {
                gigabyteField(model.binding(\.backfillGBPerHour), unit: "GB/giờ", label: "GB mỗi giờ")
            }
            Toggle("Backfill chỉ khi cắm sạc", isOn: model.binding(\.backfillOnlyOnACPower))
            Toggle("Mọi upload chỉ khi cắm sạc", isOn: model.binding(\.allUploadsOnlyOnACPower))
            Toggle("Dừng khi mạng tính phí (hotspot)", isOn: model.binding(\.pauseOnExpensiveNetwork))
        }
        SettingsSection("Dung lượng ổ Mac") {
            FormRow(
                "Ngưỡng thấp (lowWatermark)",
                detail: "Dưới mức này dừng backfill; chạy lại khi trống từ \(model.settings.lowWatermarkGB + 5) GB.") {
                gigabyteField(model.binding(\.lowWatermarkGB), unit: "GB", label: "lowWatermark GB")
            }
            FormRow("Ngưỡng nguy cấp (criticalWatermark)", detail: "Dưới mức này dừng mọi export.") {
                gigabyteField(model.binding(\.criticalWatermarkGB), unit: "GB", label: "criticalWatermark GB")
            }
            FormRow("Giới hạn staging (mềm)") {
                gigabyteField(model.binding(\.stagingSoftLimitGB), unit: "GB", label: "Staging GB")
            }
            ForEach(model.settingsIssues, id: \.self) { issue in
                Text(issue.message).font(.caption).foregroundStyle(.red).accessibilityAddTraits(.isStaticText)
            }
            Text("Ổ Mac đang trống \(VietnameseFormat.bytes(model.macFreeBytes))").font(.caption).foregroundStyle(.secondary)
        }
        SettingsSection("Toàn vẹn & bảo trì") {
            FormRow("Kiểm tra toàn vẹn mỗi") {
                HStack {
                    TextField("", value: model.binding(\.integrityCheckIntervalDays), format: .number)
                        .frame(width: 60).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Số ngày")
                    Text("ngày")
                }
            }
            FormRow(
                "Kiểm tra toàn vẹn",
                detail: model.lastIntegrityCheck.map { "Lần cuối " + RelativeTimeText.ago($0, now: Date()) } ?? "Chưa kiểm tra lần nào") {
                Button("Kiểm tra ngay") { model.runIntegrityCheck() }.disabled(!model.hardeningAvailable)
            }
            FormRow("Đối soát thư viện", detail: "Liệt kê lại toàn bộ Photos để bắt thay đổi bị sót.") {
                Button("Đối soát") { model.runReconciliation() }.disabled(!model.hardeningAvailable)
            }
            FormRow("Thử lại job bị hoãn", detail: "Đưa job deferred về hàng chờ.") {
                Button("Thử lại") { model.retryDeferred() }.disabled(!model.hardeningAvailable)
            }
            FormRow("Thử lại job bị bỏ qua", detail: "Đưa job skipped về hàng chờ.") {
                Button("Thử lại") { model.retrySkipped() }.disabled(!model.hardeningAvailable)
            }
            FormRow("Khôi phục trạng thái từ đích", detail: "Ghép lại file đã có ở đích vào cơ sở dữ liệu, không upload lại.") {
                Button("Khôi phục giúp tôi…") { confirmRecovery = true }.disabled(!model.hardeningAvailable || model.destinations.isEmpty)
            }
            if !model.hardeningAvailable {
                SettingsNote("Một số thao tác bảo trì chưa khả dụng trong bản build này.")
            }
            FormRow("Log") {
                Button("Mở thư mục log") { model.revealLog() }
            }
        }
        .confirmationDialog("Khôi phục trạng thái từ đích nào?", isPresented: $confirmRecovery) {
            ForEach(model.destinations, id: \.id) { record in
                Button(record.displayName) { model.startRecovery(record.id) }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Chỉ chạy khi scan đã hoàn tất. Đích tạm dừng (đang khôi phục) trong lúc đó.")
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
