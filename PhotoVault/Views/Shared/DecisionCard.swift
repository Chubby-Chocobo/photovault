import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// An owner prompt (FR-47, FR-76): used in the menu bar and the activity window. Actions go through `HardeningCommands`.
struct DecisionCard: View {
    @Environment(AppModel.self) private var model
    var decision: OwnerDecisionItem
    @State private var step: Step = .choices
    @State private var newRootName = "Camera Uploads 2"

    private enum Step { case choices, newRoot, confirmReupload }

    var body: some View {
        Banner(style, title: title, message: message) {
            VStack(alignment: .leading, spacing: 6) {
                actions
                if !model.hardeningAvailable {
                    Text("Hành động này chưa khả dụng trong bản build này.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.hardeningAvailable)
        }
    }

    private var style: BannerStyle {
        switch decision.kind {
        case .integrityMissing, .checksumMismatch: .danger
        default: .warning
        }
    }

    private var title: String {
        switch decision.kind {
        case .rootTrashed(let name): "Thư mục gốc “\(name)” đang ở Thùng rác"
        case .rootMissing(let name): "Không tìm thấy thư mục gốc “\(name)”"
        case .folderTrashed: "Một thư mục backup trên \(decision.destinationName) đang ở Thùng rác"
        case .recoveryNeedsDecision: "Không nhận ra dữ liệu cũ trên \(decision.destinationName)"
        case .integrityMissing(let count, _): "Kiểm tra toàn vẹn: thiếu \(VietnameseFormat.integer(count)) file trên \(decision.destinationName)"
        case .checksumMismatch: "Checksum lệch trên \(decision.destinationName)"
        }
    }

    private var message: String {
        switch decision.kind {
        case .rootTrashed:
            "PhotoVault đã tạm dừng đích \(decision.destinationName) và sẽ không tự tạo lại thư mục gốc. Các đích khác vẫn chạy bình thường."
        case .rootMissing:
            "Thư mục đã bị xoá hoặc không còn truy cập được. PhotoVault đã tạm dừng \(decision.destinationName) và sẽ không tự tạo lại."
        case .folderTrashed:
            "PhotoVault đã tạm dừng \(decision.destinationName) cho tới khi bạn quyết định. Các đích khác vẫn chạy bình thường."
        case .recoveryNeedsDecision:
            "Đích đã có dữ liệu nhưng PhotoVault ghép được chưa tới một nửa với thư viện Photos (chi tiết trong Hoạt động gần đây). PhotoVault tạm dừng đích này và không đụng tới file nào."
                + " Nếu đây đúng là thư mục backup cũ, hãy thử khôi phục lại; nếu không, tiếp tục mà không dùng dữ liệu cũ (file mới được ghi bên cạnh, không ghi đè)."
        case .integrityMissing(let count, let hints):
            "\(VietnameseFormat.integer(count)) file PhotoVault đã ghi không còn ở đích"
                + (hints.isEmpty ? "" : " (chủ yếu ở \(hints.joined(separator: ", ")))")
                + ". PhotoVault chưa upload lại; bạn quyết định."
        case .checksumMismatch(let count):
            "\(VietnameseFormat.integer(count)) file ở đích không khớp checksum. PhotoVault không ghi đè; xem Hoạt động gần đây để biết chi tiết."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch (decision.kind, step) {
        case (.rootTrashed, .choices), (.folderTrashed, .choices):
            HStack {
                Button("Khôi phục giúp tôi") { model.untrashAndContinue(decision) }
                Button("Tôi đã khôi phục") { model.ownerRestored(decision) }
                if case .rootTrashed = decision.kind { Button("Upload lại vào thư mục mới…") { step = .newRoot } }
            }
        case (.rootMissing, .choices):
            HStack {
                Button("Tôi đã khôi phục") { model.ownerRestored(decision) }
                Button("Upload lại vào thư mục mới…") { step = .newRoot }
            }
        case (_, .newRoot):
            VStack(alignment: .leading, spacing: 6) {
                Text("PhotoVault tạo thư mục gốc mới, đặt lại đích và upload lại toàn bộ (export lại từ Photos, theo giới hạn tốc độ). Thư mục cũ không bị đụng tới.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Tên thư mục mới", text: $newRootName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Tạo và upload lại") { model.uploadToNewRoot(decision, name: newRootName) }
                        .disabled(RootNameValidator.validate(newRootName) != nil)
                    Button("Huỷ") { step = .choices }
                }
            }
        case (.integrityMissing(let count, _), .choices):
            HStack {
                Button("Upload lại \(VietnameseFormat.integer(count)) file…") { step = .confirmReupload }
                Button("Để sau") { model.snooze(decision) }
            }
        case (.integrityMissing(let count, _), .confirmReupload):
            VStack(alignment: .leading, spacing: 6) {
                Text("File được ghi lại đúng chỗ và đúng tên cũ. PhotoVault export lại từ Photos, tính vào giới hạn tốc độ. Không đụng tới file nào khác.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Upload lại \(VietnameseFormat.integer(count)) file") { model.confirmReupload(decision) }
                    Button("Huỷ") { step = .choices }
                }
            }
        case (.recoveryNeedsDecision, _):
            HStack {
                Button("Thử khôi phục lại") { model.startRecovery(decision.destinationId) }
                Button("Tiếp tục không dùng dữ liệu cũ") { model.proceedWithoutRecovery(decision) }
            }
        case (.checksumMismatch, _):
            HStack {
                Button("Xem hoạt động") { model.open(.activity) }
                Button("Để sau") { model.snooze(decision) }
            }
        default:
            EmptyView()
        }
    }
}
