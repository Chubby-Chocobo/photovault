import Foundation
import PhotoVaultCore
import PhotoVaultEngine
import PhotoVaultStore

/// `HardeningCommands` backed by `SyncCoordinator`: maps the engine's types onto the app's.
struct EngineHardeningCommands: HardeningCommands {
    let coordinator: SyncCoordinator
    let store: Store

    func runReconciliation() async throws { try await coordinator.runReconciliation() }

    /// Runs per destination so mismatch counts can be attributed (the engine report only keeps totals).
    func runIntegrityCheck(_ id: DestinationID?) async throws -> IntegrityCheckSummary {
        let ids: [DestinationID]
        if let id {
            ids = [id]
        } else {
            ids = try await store.read { db in try DestinationRepository.fetchAll(db).map(\.id) }
        }
        var summary = IntegrityCheckSummary(missingFiles: [:], checksumMismatches: [:])
        for destination in ids {
            let report: PhotoVaultEngine.IntegrityReport = try await coordinator.runIntegrityCheck(destination)
            let missing = report.missingByDestination[destination] ?? report.missing
            let mismatched = report.sizeMismatch + report.hashMismatch
            if missing > 0 { summary.missingFiles[destination] = missing }
            if mismatched > 0 { summary.checksumMismatches[destination] = mismatched }
        }
        return summary
    }

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

    func startRecovery(_ id: DestinationID) async throws -> RecoveryReport {
        switch try await coordinator.startRecovery(id) {
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
        return decisions.compactMap { decision in
            guard let record = byId[decision.destinationId] else { return nil }
            let rootName = record.config.driveRootName ?? record.config.displayPath ?? record.displayName
            let kind: OwnerDecisionItem.Kind = switch decision {
            case .rootMissing: .rootMissing(rootName: rootName)
            case .rootTrashed: .rootTrashed(rootName: rootName)
            case .folderTrashed: .folderTrashed
            case .integrityMissing(_, let count): .integrityMissing(fileCount: count, folderHints: [])
            case .recoveryNeedsDecision: .recoveryNeedsDecision
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
            "PhotoVault ghép được quá ít file với thư viện nên tạm dừng đích này. Chọn cách xử lý trong menu bar."
        case .notReady(.scanIncomplete): "Cần quét xong thư viện Photos trước khi khôi phục."
        case .notReady(.cloudIdsPending): "PhotoVault đang ghép mã iCloud của ảnh. Thử lại sau ít phút."
        case .notReady(.destinationUnavailable): "Đích chưa truy cập được. Kiểm tra mạng hoặc ổ NAS."
        case .notReady(.unknownDestination): "Không tìm thấy đích này."
        case .notReady(.alreadyRunning): "Đang khôi phục đích này."
        }
    }
}
