import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// An owner prompt (FR-47, FR-76): used in the menu bar and the activity window. Actions go through `HardeningCommands`.
struct DecisionCard: View {
    @Environment(AppModel.self) private var model
    var decision: OwnerDecisionItem
    @State private var step: Step = .choices
    @State private var newRootName = "Camera Uploads 2"

    private enum Step { case choices, newRoot, confirmReupload, confirmProceed }

    var body: some View {
        Banner(style, title: title, message: message) {
            VStack(alignment: .leading, spacing: 6) {
                actions
                if !model.hardeningAvailable {
                    Text(tr(vi: "Hành động này chưa khả dụng trong bản build này.", en: "This action is not available in this build.")).font(.caption2).foregroundStyle(.secondary)
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
        let name = decision.destinationName
        switch decision.kind {
        case .rootTrashed(let rootName):
            return tr(vi: "Thư mục gốc “\(rootName)” đang ở Thùng rác", en: "The root folder “\(rootName)” is in the Trash")
        case .rootMissing(let rootName):
            return tr(vi: "Không tìm thấy thư mục gốc “\(rootName)”", en: "The root folder “\(rootName)” was not found")
        case .folderTrashed:
            return tr(vi: "Một thư mục backup trên \(name) đang ở Thùng rác", en: "A backup folder on \(name) is in the Trash")
        case .recoveryNeedsDecision:
            return tr(vi: "Không nhận ra dữ liệu cũ trên \(name)", en: "The old data on \(name) was not recognized")
        case .integrityMissing(let count, _, let mismatched):
            let number = VietnameseFormat.integer(count)
            let files = L10n.plural(count, one: "1 file", other: "\(number) files")
            return mismatched == count
                ? tr(vi: "Kiểm tra toàn vẹn: \(number) file lệch checksum trên \(name)", en: "Integrity check: \(files) with a checksum mismatch on \(name)")
                : tr(vi: "Kiểm tra toàn vẹn: thiếu \(number) file trên \(name)", en: "Integrity check: \(files) missing on \(name)")
        case .checksumMismatch:
            return tr(vi: "Checksum lệch trên \(name)", en: "Checksum mismatch on \(name)")
        }
    }

    private var message: String {
        let name = decision.destinationName
        switch decision.kind {
        case .rootTrashed:
            return tr(
                vi: "PhotoVault đã tạm dừng đích \(name) và sẽ không tự tạo lại thư mục gốc. Các đích khác vẫn chạy bình thường.",
                en: "PhotoVault paused the destination \(name) and will not recreate the root folder by itself. Other destinations keep running normally.")
        case .rootMissing:
            return tr(
                vi: "Thư mục đã bị xoá hoặc không còn truy cập được. PhotoVault đã tạm dừng \(name) và sẽ không tự tạo lại.",
                en: "The folder was deleted or can no longer be reached. PhotoVault paused \(name) and will not recreate it by itself.")
        case .folderTrashed:
            return tr(
                vi: "PhotoVault đã tạm dừng \(name) cho tới khi bạn quyết định. Các đích khác vẫn chạy bình thường.",
                en: "PhotoVault paused \(name) until you decide. Other destinations keep running normally.")
        case .recoveryNeedsDecision:
            return tr(
                vi: "Đích đã có dữ liệu nhưng PhotoVault ghép được chưa tới một nửa với thư viện Photos (chi tiết trong Hoạt động gần đây). PhotoVault tạm dừng đích này và không đụng tới file nào.",
                en: "The destination already has data, but PhotoVault could match fewer than half of it to the Photos library (details in Recent activity). PhotoVault paused this destination and touches no files.")
                + tr(
                    vi: " Nếu đây đúng là thư mục backup cũ, hãy thử khôi phục lại; nếu không, tiếp tục mà không dùng dữ liệu cũ (file mới được ghi bên cạnh, không ghi đè).",
                    en: " If this is the old backup folder, try recovery again; if not, continue without the old data (new files are written next to it, nothing is overwritten).")
        case .integrityMissing(let count, let hints, let mismatched):
            let number = VietnameseFormat.integer(count)
            let badNumber = VietnameseFormat.integer(mismatched)
            let places = hints.joined(separator: ", ")
            let one = count == 1
            let head = tr(
                vi: "\(number) file PhotoVault đã ghi không còn ở đích hoặc không khớp checksum",
                en: "\(L10n.plural(count, one: "1 file", other: "\(number) files")) that PhotoVault wrote \(one ? "is" : "are") no longer at the destination or \(one ? "does" : "do") not match the checksum")
            let bad = mismatched > 0
                ? tr(vi: " (trong đó \(badNumber) file lệch checksum)", en: " (\(badNumber) with a checksum mismatch)") : ""
            let location = hints.isEmpty
                ? "" : tr(vi: ", chủ yếu ở \(places)", en: ", mostly in \(places)")
            let tail = tr(
                vi: ". PhotoVault chưa upload lại; bạn quyết định. File lệch không bị ghi đè.",
                en: ". PhotoVault has not re-uploaded them yet; you decide. Mismatched files are not overwritten.")
            return head + bad + location + tail
        case .checksumMismatch(let count):
            let number = VietnameseFormat.integer(count)
            return tr(
                vi: "\(number) file ở đích không khớp checksum. PhotoVault không ghi đè; xem Hoạt động gần đây để biết chi tiết.",
                en: "\(L10n.plural(count, one: "1 file", other: "\(number) files")) at the destination \(count == 1 ? "does" : "do") not match the checksum. PhotoVault does not overwrite; see Recent activity for details.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch (decision.kind, step) {
        case (.rootTrashed, .choices), (.folderTrashed, .choices):
            HStack {
                Button(tr(vi: "Khôi phục giúp tôi", en: "Recover it for me")) { model.untrashAndContinue(decision) }
                Button(tr(vi: "Tôi đã khôi phục", en: "I recovered it")) { model.ownerRestored(decision) }
                if case .rootTrashed = decision.kind {
                    Button(tr(vi: "Upload lại vào thư mục mới…", en: "Upload again to a new folder…")) { step = .newRoot }
                }
            }
        case (.rootMissing, .choices):
            HStack {
                Button(tr(vi: "Tôi đã khôi phục", en: "I recovered it")) { model.ownerRestored(decision) }
                Button(tr(vi: "Upload lại vào thư mục mới…", en: "Upload again to a new folder…")) { step = .newRoot }
            }
        case (_, .newRoot):
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(
                    vi: "PhotoVault tạo thư mục gốc mới, đặt lại đích và upload lại toàn bộ (export lại từ Photos, theo giới hạn tốc độ). Thư mục cũ không bị đụng tới.",
                    en: "PhotoVault creates a new root folder, resets the destination and uploads everything again (exported again from Photos, within the rate limit). The old folder is not touched."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(tr(vi: "Tên thư mục mới", en: "New folder name"), text: $newRootName).textFieldStyle(.roundedBorder)
                HStack {
                    Button(tr(vi: "Tạo và upload lại", en: "Create and upload again")) { model.uploadToNewRoot(decision, name: newRootName) }
                        .disabled(RootNameValidator.validate(newRootName) != nil)
                    Button(tr(vi: "Huỷ", en: "Cancel")) { step = .choices }
                }
            }
        case (.integrityMissing(let count, _, _), .choices):
            HStack {
                Button(reuploadTitle(count, ellipsis: true)) { step = .confirmReupload }
                Button(tr(vi: "Để sau", en: "Later")) { model.snooze(decision) }
            }
        case (.integrityMissing(let count, _, _), .confirmReupload):
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(
                    vi: "File đã mất được ghi lại đúng chỗ và đúng tên cũ; với file lệch checksum, bản đúng được ghi bên cạnh, file lệch giữ nguyên. PhotoVault export lại từ Photos, tính vào giới hạn tốc độ. Không đụng tới file nào khác.",
                    en: "Lost files are written back to the same place under the same name; for files with a checksum mismatch, the correct copy is written next to them and the mismatched file stays. PhotoVault exports again from Photos, counted against the rate limit. No other files are touched."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(reuploadTitle(count, ellipsis: false)) { model.confirmReupload(decision) }
                    Button(tr(vi: "Huỷ", en: "Cancel")) { step = .choices }
                }
            }
        case (.recoveryNeedsDecision, .confirmProceed):
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(
                    vi: "PhotoVault upload lại toàn bộ phạm vi vào đích này, bên cạnh dữ liệu cũ (không ghi đè, không xoá). Dung lượng ở đích có thể tăng gấp đôi và không hoàn tác được.",
                    en: "PhotoVault uploads the whole scope to this destination again, next to the old data (nothing is overwritten or deleted). Space used at the destination may double, and this cannot be undone."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(tr(vi: "Tiếp tục và upload lại", en: "Continue and upload again")) { model.proceedWithoutRecovery(decision) }
                    Button(tr(vi: "Huỷ", en: "Cancel")) { step = .choices }
                }
            }
        case (.recoveryNeedsDecision, _):
            HStack {
                Button(tr(vi: "Thử khôi phục lại", en: "Try recovery again")) { model.startRecovery(decision.destinationId) }
                Button(tr(vi: "Tiếp tục không dùng dữ liệu cũ…", en: "Continue without the old data…")) { step = .confirmProceed }
            }
        case (.checksumMismatch, _):
            HStack {
                Button(tr(vi: "Xem hoạt động", en: "View activity")) { model.open(.activity) }
                Button(tr(vi: "Đã xem", en: "Mark as seen")) { model.dismissChecksumMismatch(decision) }
                Button(tr(vi: "Để sau", en: "Later")) { model.snooze(decision) }
            }
        default:
            EmptyView()
        }
    }

    private func reuploadTitle(_ count: Int, ellipsis: Bool) -> String {
        let number = VietnameseFormat.integer(count)
        let tail = ellipsis ? "…" : ""
        return tr(
            vi: "Upload lại \(number) file\(tail)",
            en: "Upload \(L10n.plural(count, one: "1 file", other: "\(number) files")) again\(tail)")
    }
}
