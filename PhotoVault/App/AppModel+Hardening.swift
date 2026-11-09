import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore

/// Owner decisions and maintenance actions that go through `HardeningCommands`.
extension AppModel {
    var hardeningAvailable: Bool { hardening != nil }

    private func withHardening(_ title: String, _ body: @escaping @MainActor (any HardeningCommands) async throws -> String?) {
        guard let hardening else {
            showNotice(tr(vi: "\(title) chưa khả dụng trong bản build này.", en: "\(title) is not available in this build."), isError: true)
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
        withHardening(tr(vi: "Đối soát thư viện", en: "Library reconciliation")) { commands in
            try await commands.runReconciliation()
            return tr(vi: "Đã đối soát thư viện.", en: "Library reconciled.")
        }
    }

    func runIntegrityCheck(_ id: DestinationID? = nil) {
        withHardening(tr(vi: "Kiểm tra toàn vẹn", en: "Integrity check")) { [weak self] commands in
            let summary = try await commands.runIntegrityCheck(id)
            if let env = self?.env {
                let now = Date()
                try await env.store.write { db in try AppQueries.recordIntegrityCheck(db, at: now) }
            }
            await self?.refresh()
            let skippedNames = summary.skipped.map { skipped in
                self?.destinations.first { $0.id == skipped }?.displayName ?? skipped.rawValue
            }
            return IntegrityNoticeText.make(
                missing: summary.missingFiles.values.reduce(0, +), mismatched: summary.checksumMismatches.values.reduce(0, +),
                skippedNames: skippedNames)
        }
    }

    func retryDeferred(_ id: DestinationID? = nil) {
        withHardening(tr(vi: "Thử lại job bị hoãn", en: "Retry deferred jobs")) { commands in
            try await commands.retryDeferred(id)
            return tr(vi: "Đã xếp hàng lại các job bị hoãn.", en: "Deferred jobs queued again.")
        }
    }

    func retrySkipped(_ id: DestinationID? = nil) {
        withHardening(tr(vi: "Thử lại job bị bỏ qua", en: "Retry skipped jobs")) { commands in
            try await commands.retrySkipped(id)
            return tr(vi: "Đã xếp hàng lại các job bị bỏ qua.", en: "Skipped jobs queued again.")
        }
    }

    func startRecovery(_ id: DestinationID) {
        withHardening(tr(vi: "Khôi phục trạng thái từ đích", en: "Recover state from the destination")) { commands in
            let report = try await commands.startRecovery(id)
            let matched = VietnameseFormat.integer(report.matchedFiles)
            let unmatched = VietnameseFormat.integer(report.unmatchedFiles)
            let matchedText = tr(
                vi: "Khôi phục xong: ghép \(matched) file",
                en: "Recovery done: matched \(L10n.plural(report.matchedFiles, one: "1 file", other: "\(matched) files"))")
            guard report.unmatchedFiles > 0 else { return matchedText + "." }
            return matchedText + tr(
                vi: ", \(unmatched) file không ghép được.",
                en: ", \(L10n.plural(report.unmatchedFiles, one: "1 file", other: "\(unmatched) files")) could not be matched.")
        }
    }

    // MARK: Owner decisions (FR-47, FR-76)

    func untrashAndContinue(_ decision: OwnerDecisionItem) {
        withHardening(tr(vi: "Khôi phục thư mục", en: "Recover folder")) { commands in
            try await commands.untrashAppItems(decision.destinationId)
            try await commands.resolveRootProblem(decision.destinationId, choice: .ownerRestored)
            return tr(vi: "Đã khôi phục thư mục. \(decision.destinationName) chạy lại.", en: "Folder recovered. \(decision.destinationName) is running again.")
        }
    }

    func ownerRestored(_ decision: OwnerDecisionItem) {
        withHardening(tr(vi: "Kiểm tra lại thư mục", en: "Recheck folder")) { commands in
            try await commands.resolveRootProblem(decision.destinationId, choice: .ownerRestored)
            return nil
        }
    }

    func uploadToNewRoot(_ decision: OwnerDecisionItem, name: String) {
        guard RootNameValidator.validate(name) == nil else {
            showNotice(RootNameValidator.validate(name)?.message ?? tr(vi: "Tên không hợp lệ.", en: "Invalid name."), isError: true)
            return
        }
        let clean = RootNameValidator.normalized(name)
        withHardening(tr(vi: "Upload vào thư mục mới", en: "Upload to a new folder")) { commands in
            try await commands.resolveRootProblem(decision.destinationId, choice: .uploadToNewRoot(name: clean))
            return tr(vi: "Đang tạo thư mục “\(clean)” và upload lại.", en: "Creating the folder “\(clean)” and uploading again.")
        }
    }

    func confirmReupload(_ decision: OwnerDecisionItem) {
        withHardening(tr(vi: "Upload lại file thiếu", en: "Re-upload missing files")) { commands in
            try await commands.confirmReupload(decision.destinationId)
            return tr(vi: "Đã xếp hàng upload lại.", en: "Re-upload queued.")
        }
    }

    func proceedWithoutRecovery(_ decision: OwnerDecisionItem) {
        withHardening(tr(vi: "Tiếp tục không dùng dữ liệu cũ", en: "Continue without the old data")) { commands in
            try await commands.proceedWithoutRecovery(decision.destinationId)
            return tr(
                vi: "\(decision.destinationName) chạy lại; file mới được ghi bên cạnh dữ liệu cũ.",
                en: "\(decision.destinationName) is running again; new files are written next to the old data.")
        }
    }

    /// "Đã xem": the engine forgets the mismatch count until a later check finds more.
    func dismissChecksumMismatch(_ decision: OwnerDecisionItem) {
        withHardening(tr(vi: "Đánh dấu đã xem", en: "Mark as seen")) { commands in
            try await commands.dismissChecksumMismatch(decision.destinationId)
            return nil
        }
    }

    /// "Để sau": hides the card for this session; the jobs stay `missingRemote`.
    func snooze(_ decision: OwnerDecisionItem) {
        snoozedDecisions.insert(decision.id)
    }
}
