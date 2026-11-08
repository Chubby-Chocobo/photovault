import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import PhotoVaultStore

/// FR-61: evaluates the notification conditions and posts what the throttle allows.
extension AppModel {
    func evaluateNotifications() async {
        guard let env, phase == .running, await notificationService.isAuthorized() else { return }
        let (diskSince, lastSync) = (try? await env.store.read { db in
            (try AppQueries.macDiskFullSince(db), try AppQueries.lastSuccessfulSync(db))
        }) ?? (nil, nil)
        var missing: [DestinationID: Int] = [:]
        var mismatches: [DestinationID: Int] = [:]
        for decision in decisions {
            switch decision.kind {
            case .integrityMissing(let count, _, let mismatched):
                if count - mismatched > 0 { missing[decision.destinationId] = count - mismatched }
                if mismatched > 0 { mismatches[decision.destinationId] = mismatched }
            case .checksumMismatch(let count): mismatches[decision.destinationId] = count
            default: break
            }
        }
        let inputs = NotificationInputs(
            onboardingComplete: true, photosAuthorization: photosAuthorization, syncPausedByOwner: isPausedAll,
            destinations: destinations.map { .init(id: $0.id, name: $0.displayName, status: $0.status, statusSince: $0.statusSince) },
            macDiskFullSince: diskSince, lastSuccessfulSyncAt: lastSync, missingFiles: missing, checksumMismatches: mismatches)
        var throttle = env.notificationLedger.load()
        let due = NotificationEvaluator.plan(inputs, throttle: &throttle, now: Date())
        guard !due.isEmpty else { return }
        do {
            try env.notificationLedger.save(throttle)
        } catch {
            // Without a saved ledger a relaunch could repeat the notification; sending is still the safer failure.
            env.log.log(.error, category: "notification", "ledger could not be saved: \(type(of: error))")
        }
        for request in due {
            do {
                try await notificationService.post(request)
                env.log.log(.info, category: "notification", "posted \(request.kind.rawValue)")
            } catch {
                env.log.log(.error, category: "notification", "post failed: \(type(of: error))")
            }
        }
    }
}
