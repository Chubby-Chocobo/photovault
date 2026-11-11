# Phase 2: Engine — runs, integrity results, retry

- **Touches:** `EligibilityService.swift`, `SyncCoordinator.swift`, `SyncMilestones.swift`, `RecoveryService.swift`, `IntegrityChecker.swift`, `IntegrityLocal.swift`, `IntegrityDrive.swift`, `RootProblemService.swift` (`RetryService`), new `SyncCoordinator+History.swift`; `Tests/PhotoVaultEngineTests/TransferHistory*Tests.swift`.
- **Acceptance:**
  - Real cycles write uploaded, updated, failed, skipped and cancelled rows; a crash between the state change and the row is impossible (one statement), shown with a rolled-back write and with a restart.
  - The first backfill, a destination added and a widened scope each make their own run; runs finish when nothing of them is pending or uploading.
  - An integrity check records a time and result per file and destination.
  - Retry of one file, of a run's failed files and of an import's failed uploads goes through `retryDeferred` / `retrySkipped` only.
  - No history code puts a file name in the log or the activity list.

## Steps

1. Tests first with the `Harness` (fake destinations, `TestClock`, no sleeps).
2. Pass the run cause from the commands through `EligibilityService` to `JobRepository.upsert`.
3. Finish runs in the drained-cycle write of `SyncMilestones`.
4. Record per-file integrity results.
5. Retry commands in the exclusive lane.
