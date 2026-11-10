---
phase: 03
title: "Engine: change feed stage"
status: pending
priority: P2
size: L
human_effort: 2-4h
dependencies: [01, 02]
touches:
  - Sources/PhotoVaultEngine/ContinuousFeedStage.swift
  - Sources/PhotoVaultEngine/ContinuousFeedStage+Apply.swift
  - Sources/PhotoVaultEngine/AssetHandover.swift
  - Sources/PhotoVaultEngine/SourceAvailability.swift
  - Sources/PhotoVaultEngine/ImportStage.swift
  - Sources/PhotoVaultEngine/ImportStage+Listing.swift
  - Sources/PhotoVaultEngine/ImportStage+Ingest.swift
  - Sources/PhotoVaultEngine/ImportHolds.swift
  - Sources/PhotoVaultEngine/SourceRegistry.swift
  - Sources/PhotoVaultEngine/SyncCoordinator.swift
  - Sources/PhotoVaultEngine/SyncCoordinator+ContinuousSources.swift
  - Sources/PhotoVaultEngine/EngineEnvironment.swift
  - Sources/PhotoVaultTestSupport/FakeContinuousSource.swift
  - Tests/PhotoVaultEngineTests/ContinuousTestKit.swift
  - Tests/PhotoVaultEngineTests/ContinuousFeedTests.swift
  - Tests/PhotoVaultEngineTests/ContinuousFeedSafetyTests.swift
  - Tests/PhotoVaultEngineTests/ContinuousHandoverTests.swift
  - Tests/PhotoVaultEngineTests/ContinuousFeedCrashTests.swift
acceptance:
  - swift test --filter "ContinuousFeed|ContinuousHandover"
  - swift test --filter "FolderImport|CloudImport|ImportHolds"
---

# Phase 03: Engine change feed

## Overview
This phase reads each continuous source's feed once per cycle. It turns the feed into `import_item` rows and retired or handed-over assets, inside transactions that also carry the cursor. It also adds the guards against mass deletion. Ingest of the rows comes in phase 04. Size L: a new cycle stage with crash-safety and data-loss rules across the engine.

## Context
- The cycle runs the `.changes` stages after Photos change tracking: `Sources/PhotoVaultEngine/SyncCoordinator+Cycle.swift:148`. The stage list is at `Sources/PhotoVaultEngine/SyncCoordinator.swift:78`, with one `ImportHolds` shared at `:69-79`.
- Availability helpers to share: `reachable`, `adapter`, `AdapterFault`, `pauseBriefly`, `holdForSignIn`, `hold` and `setStatus` in `Sources/PhotoVaultEngine/ImportStage.swift:52-135`. They are used by `ImportStage+Listing.swift:10-23` and `ImportStage+Ingest.swift:102-131`.
- Holds and reasons: `Sources/PhotoVaultEngine/ImportHolds.swift:5-104`.
- Deletion pattern: `ChangeTracker.swift:90-99`; `cancelImport` at `SyncCoordinator+Imports.swift:67-78`. Item insert pattern: `ImportStage+Listing.swift:24-42`.
- Revive by key: `ImportIngest.swift:26-34`. Take-over of a cancelled source's asset: `ImportDedupe.swift:40-46`. Job upsert never re-arms `skipped`: `Sources/PhotoVaultCore/Rules/JobTransitions.swift:269-270`. Retry of a skipped job: `(.skipped, .retrySkipped)` at `:157`.
- Crash points: `Sources/PhotoVaultEngine/EngineEnvironment.swift:20-31`. Fake precedent: `Sources/PhotoVaultTestSupport/FakeContentSource.swift`.

## Requirements
1. `SourceAvailability` (new): the helpers above, moved out of `ImportStage` with unchanged behaviour. One addition: `rootChanged` holds with reason `rootChanged` (other `SourceError`s keep `unavailable`). The import suites stay unchanged and green.
   - `ImportStage.run` filters its rows by `mode == .oneTime` here, not in phase 04. Without it, the import stage finds no folder adapter for a continuous row and holds it for sign-in on every cycle (`ImportStage.swift:24-36`, `SourceRegistry.swift:15`), so the feed tests below could not pass (re-audit I-4). Phase 04 adds the continuous ingest branch next to this filter.
2. `SourceRegistry.continuous(for:)`. New `SyncCoordinator+ContinuousSources.swift` with `registerContinuousSources(_:)` and `confirmLargeRemoval(_ id)`. The confirm command runs in the lane and acts only while the source is `offline` with reason `largeRemoval`. In one transaction it copies `blocked_removals` into `removal_allowance` and sets `watching`; then it calls `ImportHolds.clearCooldown` (re-audit I-6). The allowance lives in the database, so sign-in (`ImportHolds.clear`), a relaunch and the confirm itself never clear it. Phase 04 adds the other commands to the same file.
3. `ImportHolds` gains:
   - `notePolled` / `polledRecently`;
   - `clearCooldown(id)`: forgets only the job-wide hold;
   - `forgetGroups(id)`.

   `clear(id)` forgets all of them. The brake allowance is not held here (see the brake below).
4. `ContinuousFeedStage` (`.changes`), registered at `SyncCoordinator.swift:78` with the shared holds. It runs for each source with `mode == .continuous` and an open status:
   - With no adapter, it holds for sign-in (as imports, `ImportStage.swift:30-36`). It skips a source that is cooling down, or was polled less than 60 s ago, unless the trigger is `.manual`.
   - It calls `changes(since: cursor)` through `SourceAvailability.adapter`:
     - `accessRevoked` → `signInRequired`;
     - `rootChanged` → `rootChanged`;
     - `busy` → pause;
     - any other error → `unavailable`.

     Nothing is written on any error.
   - Known rows are fetched by:
     - the remote ids of the files and `.item` removals;
     - the rows under each `.tree` key (exact);
     - the folded `dir/stem` prefixes of the wanted paths;
     - `remote_path IN` the listed path keys (a row that moved into a path; re-audit I-2).

     A complete listing fetches every row. Then `ContinuousChangePlanner.plan` runs.
   - **Brake:** let `n` be the count of `removed` actions and `a` the source's `removal_allowance`.
     - If `n > max(50, 20 % of rows not removed)` and (`a` is NULL or `n > a`), the feed trips. In one small transaction the source holds `offline` with reason `largeRemoval` and `blocked_removals = n`; `removal_allowance` is left as it is, cursor and rows are untouched. The holds get a 10-minute cooldown (`signInBackoff`), so the delta is not replanned on every poll (re-audit M-1). The log gets counts only.
     - Otherwise the feed applies. When `a` is not NULL and the feed removed at least one row, its final transaction sets `removal_allowance` and `blocked_removals` to NULL: the allowance equals the count seen at the trip and is used at most once. A feed under the threshold leaves an unused allowance in place.
     - Removing the source clears both columns (phase 04).
   - Actions are applied in transactions of about `env.tuning.importListBatch`, split only between base groups (folded dir + stem), so every action of a path and every row of a pair commit together (re-audit M-6). The last transaction also sets the cursor, `listed_at = now` and `watching` (clearing an offline reason). An empty feed still runs it. `env.reach(.afterContinuousFeedBatchCommit)` fires after every commit.
   - Failed rows go back to pending after each applied feed: `requeueFailed(failedBefore: now − 24 h)` normally, `requeueFailed(failedBefore: nil)` after a complete listing or when a sign-in cleared the holds; then `forgetGroups`. The failure time is the row's `seen_at`, written when phase 04 marks it failed, so the cadence survives relaunches and FR-124's give-up (re-audit M-3).
   - Logging is counts only.
5. `ContinuousFeedStage+Apply`, one compare-and-set function per action. A row that no longer matches is skipped and logged.
   - `insert`/`reuse`:
     - Group key `FolderItemGrouper.groupKey`; ignored extensions become `unsupported`/"companion".
     - `seen_at = now` when the source's `listed_at` is non-nil.
     - An insert re-checks `isFree` and takes the next `(n)` if needed.
   - `returned`:
     - With `restore`: `AssetHandover.restore` for the primary (once per asset), then each row of the asset back to `imported` (primary or companion) when the restore worked, or to `duplicate` of the asset when another source took it over meanwhile (re-audit M-7, M-8).
     - Without: back to pending, as a `changed` row.
   - `changed`: reset to `pending` (or `unsupported`) with `seen_at = now`. The group key is `FolderItemGrouper.groupKey(rel_path)` plus the feed's token (`"#v"` + 8 hex of the SHA-256 of the new cursor), unless the row was already pending; keys never grow and a pair changed together stays one group (re-audit M-4). Then `AssetHandover.retire` for `supersedes`.
   - `moved`: `setRemotePath`.
   - `removed`: `markRemoved`, then `AssetHandover.retire` for `supersedes`.
   - The rows the plan removes or changes form the hand-over exclusion set. Dirty days are recounted once per transaction (`AssetFinalizer.recount`).
6. `AssetHandover` (new):
   - `retire(db, key, sourceId, relativePath, excluding:, context, extensions, dirty:)`. It acts only when the asset is live, has `source_id == sourceId` and `local_id == ImportLocator(sourceId, relativePath).localId`. It:
     1. sets `deleted_at = now` and `local_id += "#" + key.identifier.prefix(16)`;
     2. upserts the asset;
     3. calls `EligibilityService.recompute` (pending and deferred jobs cancelled; done jobs and destination files untouched);
     4. marks the camera day dirty;
     5. `requeue`s `holders(key, excluding:)` with the group suffix `"#h"`; `requeue` also moves an `importing` one-time import that receives a row back to `scanning`, so it reads the row and can still complete (re-audit I-1).
   - `handOver(db, key, excluding:)`: only step 5, for a live asset that stays (used by source removal in phase 04).
   - Exclusion sets are `Set<ItemRef>` (phase 02).
   - `restore(db, key, sourceId, relativePath, context, extensions, dirty:)`. It acts only when the asset is deleted, belongs to this source and its `local_id` is this row's retired form. It clears `deleted_at`, restores `local_id`, calls `AssetFinalizer.finalize`, and moves jobs skipped for `resourceMissing` back with `.retrySkipped`.
7. `CrashPoint.afterContinuousFeedBatchCommit` (one case).
8. `FakeContinuousSource` (TestSupport):
   - Files by remote id: path, bytes, hash = SHA-256 of the bytes.
   - Operations: `add`, `modify`, `delete`, `move`, `renameCase`, `deleteFolder`, `unmountFolder`/`remountFolder` (ids kept), `replaceRoot` and `deleteRoot` (later calls throw `rootChanged`), `expireCursor` (the next call is `isComplete`), `modifyDuringRead` (the next inspect returns other bytes and their hash).
   - Toggles: `online`, `revoked`, `busy`.
   - Behaviour: the cursor is the journal position, compacted to net state per path key; deletes come as `.tree`. It counts `changes` calls and downloads. `inspect` returns `contentHash`, and `exportResource` reads `locator.remoteId`.

## Implementation steps
1. Build `ContinuousTestKit` (engine over `FakePhotosSource`, `FakeContinuousSource`, `FakeDestination` and `TestClock`), then write the red tests. Continuous ingest arrives in phase 04, so the kit seeds `imported` rows and their assets directly; phase 03 tests check rows, `deleted_at`, `local_id` and requeued rows, and the end-to-end "revived with no upload" checks run in phase 04.
2. Extract `SourceAvailability` and run the import suites, which must pass untouched.
3. Registry, holds, stage, apply, hand-over, crash point and fake.

## Tests
- `ContinuousFeedTests`:
  - first feed: NULL `seen_at`, cursor stored; a later addition sets `seen_at`;
  - modify, delete, move, case-only rename (no change), move out and back with an unchanged hash (restored, no download), folder delete, unmount and remount;
  - a same-name file after a move gives `stem (2).ext`; an existing `IMG (2).jpg` row gives `(3)`;
  - delete and re-add of the same name with a new id in one delta, and a folder deleted and recreated in one delta: the old rows are removed and the new ids reuse them (no `(2)`);
  - move out and back of a seeded RAW+JPEG pair: both rows restored, no download; with the asset taken over by another source meanwhile, both rows become `duplicate`;
  - more than 500 mixed actions, including `removed(p)` + `reuse(p)` pairs at a batch edge, give the right final rows;
  - complete listing after `expireCursor`; poll throttle;
  - offline, busy and revoked transitions, and the return to `watching`;
  - failed rows retried 24 h after their failure time (not at launch, not hourly) and at once after a sign-in or a complete listing;
  - a one-time import row is never read.
- `ContinuousFeedSafetyTests`:
  - `replaceRoot` (rename and recreate `/Camera Uploads`) then `expireCursor`: 0 rows removed, `offline/rootChanged`, cursor unchanged;
  - `deleteRoot`: the same;
  - deleting 60 of 100 files trips the brake (`largeRemoval`, `blocked_removals = 60`, nothing committed, 10-minute cooldown, no second planning inside it); `confirmLargeRemoval` sets the allowance to 60 and clears the cooldown; the next feed applies once and clears the allowance; a second large removal trips again;
  - confirm, then a sign-in and an engine rebuilt over the same database (relaunch) before the next feed: the allowance is still 60 and the feed applies once;
  - confirm 60, then a feed removing 61: trips again with `blocked_removals = 61` (no margin) and the allowance stays unused;
  - removing the source clears the allowance;
  - `confirmLargeRemoval` on a source that is not held for `largeRemoval` does nothing;
  - 40 of 1 000 is applied without a stop.
- `ContinuousHandoverTests`:
  - in-source copy: `/A/x.jpg` primary, `/B/x.jpg` duplicate; deleting `/A` retires the asset and requeues `/B` with `seen_at = NULL`;
  - RAW deleted, JPEG kept: the JPEG row is requeued as its own group;
  - a second watched folder holding a duplicate gets its row requeued;
  - a one-time import in `importing` with a duplicate row: the row is requeued, the import goes back to `scanning`, the existing import stage reads the row (revives the asset) and the import then completes with one activity row;
  - the excluded rows of the same plan are not requeued;
  - a closed one-time import's duplicate row is untouched (documented limit).
- `ContinuousFeedCrashTests`:
  - a crash after the first of three batches of a first listing: no duplicates after restart, and the cursor is set once;
  - a crash after a removal batch but before the cursor commit: the removal is applied once and nothing is lost;
  - a crash after a `changed` batch: re-delivery does not retire twice;
  - a crash after a hand-over batch: the requeued rows are ingested once.

## Risks and rollback
- Moving the availability helpers can change import behaviour. Mitigation: a pure move, with the import suites as the gate.
- The brake thresholds (50 rows, 20 %) are guesses. A legitimate large cleanup asks once more. Review later.
- `EngineEnvironment.swift` gets a one-line edit next to feat/27's.
- Unknown: the memory used by a whole-account first listing (it is held in memory, as for imports).
- Rollback: revert. Rows already written stay, unread.
