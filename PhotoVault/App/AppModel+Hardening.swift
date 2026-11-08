import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore

/// Owner decisions and maintenance actions that go through `HardeningCommands`.
extension AppModel {
    var hardeningAvailable: Bool { hardening != nil }

    private func withHardening(_ title: String, _ body: @escaping @MainActor (any HardeningCommands) async throws -> String?) {
        guard let hardening else {
            showNotice("\(title) chưa khả dụng trong bản build này.", isError: true)
            return
        }
        Task {
            do {
                if let message = try await body(hardening) { showNotice(message) }
                requestSync(.manual)
                await refreshSnapshot()
            } catch {
                showError(error)
            }
        }
    }

    func runReconciliation() {
        withHardening("Đối soát thư viện") { commands in
            try await commands.runReconciliation()
            return "Đã đối soát thư viện."
        }
    }

    func runIntegrityCheck(_ id: DestinationID? = nil) {
        withHardening("Kiểm tra toàn vẹn") { [weak self] commands in
            let summary = try await commands.runIntegrityCheck(id)
            if let env = self?.env {
                let now = Date()
                try await env.store.write { db in try AppQueries.recordIntegrityCheck(db, at: now) }
            }
            if summary.isClean { return "Kiểm tra xong: không thiếu file nào." }
            let missing = summary.missingFiles.values.reduce(0, +)
            return "Kiểm tra xong: thiếu \(VietnameseFormat.integer(missing)) file. Xem trong menu bar để quyết định."
        }
    }

    func retryDeferred(_ id: DestinationID? = nil) {
        withHardening("Thử lại job bị hoãn") { commands in
            try await commands.retryDeferred(id)
            return "Đã xếp hàng lại các job bị hoãn."
        }
    }

    func retrySkipped(_ id: DestinationID? = nil) {
        withHardening("Thử lại job bị bỏ qua") { commands in
            try await commands.retrySkipped(id)
            return "Đã xếp hàng lại các job bị bỏ qua."
        }
    }

    func startRecovery(_ id: DestinationID) {
        withHardening("Khôi phục trạng thái từ đích") { commands in
            let report = try await commands.startRecovery(id)
            return "Khôi phục xong: ghép \(VietnameseFormat.integer(report.matchedFiles)) file"
                + (report.unmatchedFiles > 0 ? ", \(VietnameseFormat.integer(report.unmatchedFiles)) file không ghép được." : ".")
        }
    }

    // MARK: Owner decisions (FR-47, FR-76)

    func untrashAndContinue(_ decision: OwnerDecisionItem) {
        withHardening("Khôi phục thư mục") { commands in
            try await commands.untrashAppItems(decision.destinationId)
            try await commands.resolveRootProblem(decision.destinationId, choice: .ownerRestored)
            return "Đã khôi phục thư mục. \(decision.destinationName) chạy lại."
        }
    }

    func ownerRestored(_ decision: OwnerDecisionItem) {
        withHardening("Kiểm tra lại thư mục") { commands in
            try await commands.resolveRootProblem(decision.destinationId, choice: .ownerRestored)
            return nil
        }
    }

    func uploadToNewRoot(_ decision: OwnerDecisionItem, name: String) {
        guard RootNameValidator.validate(name) == nil else {
            showNotice(RootNameValidator.validate(name)?.message ?? "Tên không hợp lệ.", isError: true)
            return
        }
        let clean = RootNameValidator.normalized(name)
        withHardening("Upload vào thư mục mới") { commands in
            try await commands.resolveRootProblem(decision.destinationId, choice: .uploadToNewRoot(name: clean))
            return "Đang tạo thư mục “\(clean)” và upload lại."
        }
    }

    func confirmReupload(_ decision: OwnerDecisionItem) {
        withHardening("Upload lại file thiếu") { commands in
            try await commands.confirmReupload(decision.destinationId)
            return "Đã xếp hàng upload lại."
        }
    }

    func proceedWithoutRecovery(_ decision: OwnerDecisionItem) {
        withHardening("Tiếp tục không dùng dữ liệu cũ") { commands in
            try await commands.proceedWithoutRecovery(decision.destinationId)
            return "\(decision.destinationName) chạy lại; file mới được ghi bên cạnh dữ liệu cũ."
        }
    }

    /// "Để sau": hides the card for this session; the jobs stay `missingRemote`.
    func snooze(_ decision: OwnerDecisionItem) {
        snoozedDecisions.insert(decision.id)
    }
}
