import Foundation
import PhotoVaultCore
import PhotoVaultEngine
import PhotoVaultStore

/// `HardeningCommands` backed by `SyncCoordinator`: maps the engine's types onto the app's.
struct EngineHardeningCommands: HardeningCommands {
    let coordinator: SyncCoordinator
    let store: Store
    var log: any LogSink = NullLogSink()

    func runReconciliation() async throws { try await coordinator.runReconciliation() }

    /// Runs per destination so counts can be attributed. A destination the engine could not reach is
    /// reported in `skipped`; the others are still checked.
    func runIntegrityCheck(_ id: DestinationID?) async throws -> IntegrityCheckSummary {
        let ids: [DestinationID]
        if let id {
            ids = [id]
        } else {
            ids = try await store.read { db in try DestinationRepository.fetchAll(db).map(\.id) }
        }
        var summary = IntegrityCheckSummary(missingFiles: [:], checksumMismatches: [:], skipped: [])
        for destination in ids {
            let report: PhotoVaultEngine.IntegrityReport
            do {
                report = try await coordinator.runIntegrityCheck(destination)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One unreachable destination (a Drive 5xx, a timeout) must not hide the others' results.
                log.log(.error, category: "integrity", "check skipped for a destination: \(type(of: error))")
                summary.skipped.append(destination)
                continue
            }
            if report.skippedDestinations.contains(destination) {
                summary.skipped.append(destination)
                continue
            }
            let missing = report.missingByDestination[destination] ?? 0
            let mismatched = report.mismatchByDestination[destination] ?? 0
            if missing > 0 { summary.missingFiles[destination] = missing }
            if mismatched > 0 { summary.checksumMismatches[destination] = mismatched }
        }
        return summary
    }

    func dismissChecksumMismatch(_ id: DestinationID) async throws { try await coordinator.dismissChecksumMismatch(id) }

    func confirmReupload(_ id: DestinationID) async throws { try await coordinator.confirmReupload(id) }
    func retryDeferred(_ id: DestinationID?) async throws { try await coordinator.retryDeferred(id) }
    func retrySkipped(_ id: DestinationID?) async throws { try await coordinator.retrySkipped(id) }
    func untrashAppItems(_ id: DestinationID) async throws { try await coordinator.untrashAppItems(id) }

    func resolveRootProblem(_ id: DestinationID, choice: RootProblemResolution) async throws {
        let engineChoice: RootProblemChoice = switch choice {
        case .ownerRestored: .ownerRestored
        case .uploadToNewRoot(let name): .uploadToNewRoot(name: name)
        }
        try await coordinator.resolveRootProblem(id, choice: engineChoice)
    }

    func adoptExistingRoot(_ id: DestinationID, rootId: String) async throws {
        try await coordinator.adoptExistingRoot(id, rootId: rootId)
    }

    func startRecovery(_ id: DestinationID, onlyIfRequired: Bool) async throws -> RecoveryReport {
        switch try await coordinator.startRecovery(id, onlyIfRequired: onlyIfRequired) {
        case .recovered(let stats):
            return RecoveryReport(matchedFiles: stats.matched, unmatchedFiles: stats.unmatched)
        case .needsOwnerDecision:
            throw RecoveryCommandError.needsOwnerDecision
        case .notReady(let blocker):
            throw RecoveryCommandError.notReady(blocker)
        }
    }

    func proceedWithoutRecovery(_ id: DestinationID) async throws { try await coordinator.proceedWithoutRecovery(id) }

    func pendingOwnerDecisions() async -> [OwnerDecisionItem] {
        let decisions = await coordinator.pendingOwnerDecisions()
        guard !decisions.isEmpty else { return [] }
        let records = (try? await store.read { db in try DestinationRepository.fetchAll(db) }) ?? []
        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Mismatched files are also waiting for re-upload: fold their count into the missing-files card
        // so the owner sees one card with one "Upload lại" action.
        var mismatched: [DestinationID: Int] = [:]
        var hasMissing: Set<DestinationID> = []
        for decision in decisions {
            switch decision {
            case .checksumMismatch(let id, let count): mismatched[id] = count
            case .integrityMissing(let id, _): hasMissing.insert(id)
            default: break
            }
        }
        return decisions.compactMap { decision in
            if case .checksumMismatch(let id, _) = decision, hasMissing.contains(id) { return nil }
            guard let record = byId[decision.destinationId] else { return nil }
            let rootName = record.config.driveRootName ?? record.config.displayPath ?? record.displayName
            let kind: OwnerDecisionItem.Kind = switch decision {
            case .rootMissing: .rootMissing(rootName: rootName)
            case .rootTrashed: .rootTrashed(rootName: rootName)
            case .folderTrashed: .folderTrashed
            case .integrityMissing(let id, let count):
                .integrityMissing(fileCount: count, folderHints: [], mismatched: min(count, mismatched[id] ?? 0))
            case .recoveryNeedsDecision: .recoveryNeedsDecision
            case .checksumMismatch(_, let count): .checksumMismatch(fileCount: count)
            }
            return OwnerDecisionItem(destinationId: record.id, destinationName: record.displayName, kind: kind)
        }
    }
}

/// Recovery outcomes that are not a success, shown to the owner as messages.
enum RecoveryCommandError: Error, Equatable {
    case needsOwnerDecision
    case notReady(RecoveryBlocker)

    var message: String {
        switch self {
        case .needsOwnerDecision:
            tr(
                vi: "PhotoVault ghép được quá ít file với thư viện nên tạm dừng đích này. Chọn cách xử lý trong menu bar.",
                en: "PhotoVault matched too few files with the library, so it paused this destination. Choose what to do in the menu bar.")
        case .notReady(.scanIncomplete): tr(vi: "Cần quét xong thư viện Photos trước khi khôi phục.", en: "The Photos library must finish scanning before recovery.")
        case .notReady(.cloudIdsPending): tr(vi: "PhotoVault đang ghép mã iCloud của ảnh. Thử lại sau ít phút.", en: "PhotoVault is matching the iCloud IDs of the photos. Try again in a few minutes.")
        case .notReady(.destinationUnavailable): tr(vi: "Đích chưa truy cập được. Kiểm tra mạng hoặc ổ NAS.", en: "The destination can’t be reached yet. Check the network or the NAS.")
        case .notReady(.unknownDestination): tr(vi: "Không tìm thấy đích này.", en: "This destination was not found.")
        case .notReady(.legacyLayout):
            tr(
                vi: "Thư mục này chứa bản sao lưu của PhotoVault 0.1.0 (bố cục cũ) nên không dùng lại được. Hãy chuyển nó vào Thùng rác hoặc chọn thư mục khác.",
                en: "This folder holds a PhotoVault 0.1.0 backup (the old layout), so it can’t be reused. Move it to the Trash or pick another folder.")
        case .notReady(.alreadyRunning): tr(vi: "Đang khôi phục đích này.", en: "This destination is being recovered.")
        }
    }
}
