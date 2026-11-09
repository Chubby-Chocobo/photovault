# Fix: engine pipeline findings I1-I5, S12, S13

Verify: `swift test --scratch-path .build-pipe --filter "PhotoVaultEngineTests|PhotoVaultStoreTests|PhotoVaultCoreTests"` ran 493 tests; all of mine pass. The only failure is another agent's new `IntegrityRootStateTests.shortcutsOfAnotherRootInTheSameAccountAreLeftAlone` (Drive shortcuts, not my files). An earlier run had 8 failures in Offline/DestinationHealth/RecoveryTrigger/View/ExclusiveLane/PlaceName tests. They also failed with every one of my files reverted in a scratch copy, and they were gone on the next run (other agents' in-flight edits).

## Per finding

- **I1 export pass spin** (`ExportWorker.swift`, `EngineQueries.resetExportToNone`)
  - Per-pass `failed` set is excluded from the refetch.
  - A Photos-level failure (`destinationLevel`: notAuthorized, libraryUnavailable; or `.cancelled` with no permit reason and no task cancellation) sets `photosLost`; the pass stops dispatching, drains in-flight work, and returns `photosUnavailable = true` (new field on `ExportPassResult`). The cycle re-checks access at its next boundary.
  - `destinationLevel`/`transient`/`verify`/unexplained-cancel set `next_export_attempt_at = now + 60 s` (`ExportWorker.transientRetryDelay`).
  - Test: `ExportPassFailureTests.passEndsWhenPhotosIsLost` (3 errors), `itemFailureIsNotRetriedInTheSamePass`.
  - Before: 3,440 attempts in 2 s (audit probe). After: attempts = in-flight limit (2), pass ends.
  - `ExportWorker` split: size-rule helpers moved to `ExportWorker+SizeRules.swift` (`env` is now internal).
- **I2 classify pass** (`ClassifyWorker.runPass`, new `ClassifyQueries.swift`, migration `v4-provisional-index`)
  - Keyset paging on (inserted first, `COALESCE(creation_date,'')` desc, key desc) over a partial index `asset_provisional_order`; no sort, range seek.
  - `ClassifyScope` (from destinations) narrows the walk to assets that can possibly qualify: newOnly/since pre-baseline assets and destinations without camera/saved are never read. `Eligibility.needsClassification` still decides per asset.
  - First `rateLimited` refusal on non-incremental work ends the pass.
  - `ClassifyResult.walked` counts rows looked at.
  - Tests: `ClassifyPassWalkTests` - `assetsThatCanNeverQualifyAreNotWalked` (walked == 0 over 300), `eachProvisionalAssetIsWalkedOncePerPass` (200 -> 200), `passStopsAtTheFirstRateLimitedRefusal` (walked == 1), `pagingVisitsEveryRowOnceInClassifyOrderAndUsesTheIndex` (1,000 rows, 40 pages, plan uses the index, no TEMP B-TREE).
  - Before: quadratic (8.5 s at 16k, audit). A single SQL index walk per pass remains for `since` scopes; it does no Swift work per row.
- **I3 deleted asset** (`EligibilityService.recompute`): each pending/deferred job of a deleted asset is cancelled individually; done jobs stay. Uploading jobs cannot take `.cancel` (invalid transition) and are left to finish. Open question answered: cancel the remaining ones.
  - Test: `DeletedAssetAndClockTests.deletedLivePhotoCancelsRemainingJobsAndKeepsDoneOnes`.
  - Before: `pairedVideo == pending`, `snapshot.pending == 1`, backfill 0/1. After: cancelled, 0 pending, backfill done == total. Checked failing with the old code restored.
- **I4 newOnly vs wall clock** (`ChangeTracker.apply`): `insertedAt = max(now, latest baselineAt of any destination)` for changes replayed from history. Assets present at baseline (scan path, `insertedAt: nil`) are unchanged.
  - Tests: `photoAddedAfterBackwardClockStepIsStillNewForNewOnly`, `assetPresentAtBaselineStaysOutOfNewOnly`.
  - Before: jobs `[]`, 0 files (checked failing with the old code). After: planned and uploaded.
- **I5 snapshot cost** (Store migration `v3-snapshot-counters` in `SchemaSnapshotCounters.swift`, `SnapshotCounterRepository.swift`, `EngineQueries`, `SnapshotBuilder`)
  - Triggers on `upload_job` (insert/update/delete, any writer) maintain `job_count(destination,state)`, `backfill_asset(asset_key,total,open)`, `snapshot_counter('uploaded_bytes')` + `job_bytes`. The migration fills them from existing rows.
  - The snapshot reads a few small rows: one `job_count` read for all destinations and totals, two counts on `backfill_asset`, one counter row. No `upload_job` scan, independent of job count.
  - `uploadedBytes` now counts the resource size at the moment the job became `done` (was: current size of the resource).
  - Tests (`SnapshotCounterTests`): counters equal oracle `GROUP BY`/`DISTINCT`/`SUM` after bulk inserts (2,000 assets x 2 resources x 2 destinations, batched), updates (state, origin, asset_key), deletes; migration of pre-existing rows; EXPLAIN QUERY PLAN of the four reads never mentions `upload_job`. I did not build 800k rows (trigger cost on inserts) nor measure wall time; the reads are O(groups).
  - Cost: each job write now runs ~6 trigger statements.
- **S12** (`EngineQueries.apply`): only `JobTransitionError` is skipped; database errors propagate. Tests: `EngineQueriesApplyTests` (`databaseErrorsReachTheCaller` failed with the old `try?`).
- **S13** (`SettingsStore.swift`)
  - `decode` is tolerant: stored JSON is merged key by key over the defaults; a missing or no-longer-decodable key costs only that setting; unknown keys ignored; the log line names no key or value (`settings: stored setting could not be read`). New optional `log` init parameter (default `NullLogSink`, so `AppEnvironment` compiles unchanged; it should pass its log sink).
  - `update` queues behind the previous update, then reads, mutates and writes inside one transaction. `mutate` is now `@escaping @Sendable`.
  - Tests: `SettingsStoreTests` (4). I edited `EngineTestKit.swift` `Harness.update` to take an `@escaping` closure.
  - Before: probe lost one of two concurrent updates (audit).

## Files changed

Sources: `PhotoVaultEngine/{ExportWorker,ClassifyWorker,EngineQueries,EligibilityService,ChangeTracker,SnapshotBuilder,SettingsStore}.swift`; new `PhotoVaultEngine/{ClassifyQueries,ExportWorker+SizeRules}.swift`; `PhotoVaultStore/Schema.swift` (two new migrations registered); new `PhotoVaultStore/{SchemaSnapshotCounters,SnapshotCounterRepository}.swift`.
Tests: new `PhotoVaultEngineTests/{ExportPassFailureTests,ClassifyPassWalkTests,DeletedAssetAndClockTests,SettingsStoreTests,EngineQueriesApplyTests}.swift`, new `PhotoVaultStoreTests/SnapshotCounterTests.swift`; edited `EngineTestKit.swift` (one signature). Not touched: Baseline, Scanner, StagingManager, Eligibility.swift (not needed).

## Left or needing changes outside my files

- `AppModel` still polls the snapshot every 10 s (controller's part); it is now cheap.
- `AppEnvironment.swift:95`: pass `log:` to `SettingsStore` so a real decode failure is logged.
- `SyncCoordinator+Cycle`: `ExportPassResult.photosUnavailable` is not read; the cycle ends the round through `progress == 0`. A later change may use it to skip the rest of the round.
- S2-style note: the `since` scope still does one cheap SQL index walk per classify pass (see I2).

Status: DONE_WITH_CONCERNS
Summary: I1-I5, S12 and S13 are fixed, each with new tests; those pass, and I3, I4 and S12 were confirmed to fail on the old code. One engine test from another agent (`IntegrityRootStateTests`, Drive shortcuts) fails and is outside my files. I5 was checked by oracle and query-plan tests, not by timing at 800k rows.
