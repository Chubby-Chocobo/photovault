import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Step 8: pending moves and folder renames.
struct MoveStage: CycleStage {
    let worker: MoveWorker
    var step: CycleStep { .moves }
    func run(trigger: SyncTrigger) async throws -> Bool { try await worker.runPass() > 0 }
}

/// Step 9: names day folders from cached geocodes and asks for the missing geocodes. The namer runs
/// again after geocoding, so a day whose last cell just arrived is named in the same round.
struct PlaceNamerStage: CycleStage {
    let namer: PlaceNamer
    let scheduler: GeocodeScheduler
    var step: CycleStep { .placeNamer }

    func run(trigger: SyncTrigger) async throws -> Bool {
        var changed = try await namer.runPass()
        let requests = try await scheduler.runPass()
        if requests > 0 { changed += try await namer.runPass() }
        return changed > 0 || requests > 0
    }
}

/// Everything phase 9 adds to the cycle: stages in spec 8.4 order plus the owner actions.
struct OrganizationServices: Sendable {
    let env: EngineEnvironment
    let scheduler: GeocodeScheduler
    let stages: [any CycleStage]

    init(env: EngineEnvironment, uploader: UploadRunner, resourceGuard: ResourceGuard) {
        self.env = env
        scheduler = GeocodeScheduler(env: env)
        stages = [
            EditGateStage(gate: EditGate(env: env, resourceGuard: resourceGuard)),
            SidecarStage(env: env),
            ViewStage(env: env, uploader: uploader, resourceGuard: resourceGuard),
            DescriptionStage(env: env, resourceGuard: resourceGuard),
            MoveStage(worker: MoveWorker(env: env, uploader: uploader)),
            PlaceNamerStage(namer: PlaceNamer(env: env), scheduler: scheduler),
        ]
    }

    /// Settings changed: views, sidecars and descriptions are recomputed from the database.
    func settingsChanged() async throws {
        try await env.store.write { db in try DirtyQueue.requestSweep(db, [.view, .sidecar, .description]) }
    }
}
