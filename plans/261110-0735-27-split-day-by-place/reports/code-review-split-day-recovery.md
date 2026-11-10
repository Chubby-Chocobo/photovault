# Code review: split-day store and recovery (issue #27)

Scope: `git diff origin/release/0.4.0...HEAD` at 5ace4cd. Covered: store (`v6-day-place`, newer-schema guard, repositories), `DaySlotBinding`, `RecoveryWriter.writeFolders`/`writeFiles`, `RemoteInventory` (Drive `@slot`, local multi-folder days), `RecoveryService` wiring, the timezone restore, legacy probes and the docs. Split evaluation and moves are out of scope (another reviewer covers them).

Checks run:
- Full `swift test` in a throwaway worktree at HEAD: **1315 tests in 216 suites passed**.
- Probes in that worktree (`ZZAudit*`; the worktree has since been removed). Their results are quoted below.

## Critical

### C1. Recovering the NAS before Drive moves Drive files into the wrong folders and drops a Drive folder

The ADR, the system architecture doc and spec §8.15 all promise "any destination kind, any recovery order". That promise does not hold.

**Mechanism.**
- `runPending` recovers destinations in `created_at, id` order (`DestinationRepository.swift:12`). So a NAS added before Drive is recovered first.
- Its local fallback guesses that the first folder by name is the main folder (`DaySlotBinding.swift:57`). That guess lands in `day_stat`/`day_place`.
- Drive is then bound against those guessed slots. Its `writeFiles` keeps them, because `daysWithRows` (`RecoveryService.swift:142`) is taken per destination and already contains the rows the NAS pass just inserted.
- The Drive folders' ids and `pvLogical` say otherwise, so `write` (`RecoveryWriter.swift:248-250`) queues moves.

**Probe 1: R6 with the NAS created 1 s before Drive.** A restored backup from before the split; Đà Lạt (10) is the main group and Hà Nội (3) the extra one.
- The NAS pass binds Hà Nội → `camera/<day>` and Đà Lạt → `@r22b4…`.
- The Drive pass then queues **39 `moveFile`s**, and they run:
  - the Đà Lạt files go into a new Drive folder `@r…` named "2026-10-23 Đà Lạt";
  - the Hà Nội files go into the old main folder, which is also named "2026-10-23 Đà Lạt".
- End state: two Drive folders with the same name, Hà Nội photos inside a "Đà Lạt" folder, and an empty "Hà Nội" folder.

**Probe 2: R7 (the NAS holds only the small group), lost database, both destinations recovered in one pass, NAS first.**
1. NAS: Đà Lạt → main.
2. Drive: the Hà Nội folder has no name match and binds by `pvLogical` to `camera/<day>`. The Đà Lạt folder then matches main by name, finds it already bound, and is **dropped as a conflict**.
3. The namer then gives main to Đà Lạt and a new slot to Hà Nội, which means **30 Drive moves** into a second folder named "2026-10-23 Hà Nội".
4. The listing compared by path is unchanged, because the two folders have the same name. The `move_job` count is what catches it.

The shipped tests miss this (see I1).

**Fix:**
1. In `runPending`, recover destinations with `supportsAppProperties` first, then by `created_at`.
2. In a pass where such a destination still needs recovery and did not succeed (offline, `notReady`), defer local destinations. A local guess must never become the slot truth that Drive is then forced to follow.
3. Add both probes as tests: a single pass, the NAS created earlier, and assert zero `move_job`s.
4. Then correct the "any order" wording in the ADR, the architecture doc and §8.15, or keep it only once it is proven.

## Important

### I1. The order-sensitive tests do not test the order they name
- **`r6…(driveFirst: false)` is phantom.** Both destinations get the same `created_at` (`addDrive`/`addNAS` use `clock.now`), and `"gdrive" < "local-…"`, so Drive is recovered first in both arguments. I confirmed this in a probe.
- **`r3b` adds Drive only after the NAS pass and 10 settle rounds.** The namer re-splits the day in between, so the Drive pass binds against namer slots, not against the NAS guess. Production recovers every destination in one `runPending` pass.
- **`listing()` compares path strings.** A move between two Drive folders with the same name is invisible to it (probe 2). R1–R5 and R7 also count all `move_job` rows. That count is meaningful, because done rows are never deleted. R6 counts only `moveFile`.
- **Fix:**
  - advance the clock between the adds so `created_at` sets the order;
  - recover both destinations in one pass;
  - list Drive by folder id plus path.

### I2. Files in a conflict-dropped folder are still adopted, with `remote_logical_parent = NULL`
- **What the binder does.** `DaySlotBinding` sets `parentLogical = nil` for the files of a dropped folder (`DaySlotBinding.swift:85-86`). The spec ("file trong đó không được nhận"), the activity text ("its files are untouched") and `DaySlotBindingTests.twoListedFolders…` ("not adopted") all treat that as non-adoption.
- **What actually happens.** `RecoveryMatcher` still matches these files, and `write` saves a `done` job with the file's `remoteId` and `remoteLogicalParent` NULL or stale (`RecoveryWriter.swift:217`). In probe 2 the Drive pass reported 39 recovered files, including the 9 in the dropped folder.
- **Consequences:**
  - `DaySplitWriter.enqueueMoves` skips rows where `remote_logical_parent IS NULL`, so these files never follow a later slot change.
  - A replace-in-place sidecar records the planned main folder as its parent.
  - The folder stays untracked for good.
  - The unit test asserts only `parentLogical == nil`, which is a phantom check of "not adopted".
- **Fix:** have `bind` return the dropped folder ids, and have the matcher or writer leave their files unmatched. The asset then uploads into its bound folder: duplicate bytes, but tracked. Test that through `RecoveryService`, not only the binder.

### I3. `DaySplitWriter.reserved` scans the whole `move_job` table
- **The query.** It filters `WHERE subject = ? AND op = 'renameFolder' AND state IN (…)` without `destination_id` (`DaySplitWriter.swift:84-86`). The new index `move_job_subject(destination_id, subject)` cannot serve it: `EXPLAIN QUERY PLAN` gives `SCAN move_job`.
- **The table only grows.** `move_job` rows are never deleted (there is no `DELETE FROM move_job` anywhere), so every executed split move stays.
- **Callers:**
  - `knownSlots`, once per slot of every listed day, in one recovery read;
  - `DaySplitWriter`, once per evaluated day inside the `PlaceNamer` write transaction, which includes the full upgrade backfill.
- **Cost.** In an sqlite3 probe, 3000 lookups over 100k rows took **7.5 s**.
- **Fix:** add `destination_id IN (SELECT id FROM destination)` so the index is used, add an index on `(subject, op)`, or load all open renames once per pass.

## Minor

- **M1. The newer-schema refusal is indistinguishable from other failures.**
  - The launch failure is the generic "Could not open the database".
  - The log records only `type(of: error)` = `StoreError` (`AppEnvironment.swift:128`).
  - The README promises a refusal, but the owner gets no hint to install the newer build.
  - Fix: map `.newerSchema` to its own `LaunchFailure` text.
- **M2. The guard in `Store.inMemory` is dead code.** A fresh `DatabaseQueue` is never superseded (`Store.swift:58`). It is harmless; drop it or keep it for symmetry.
- **M3. R9 does not test the real path.** It calls `RecoveryService.clearDayState` directly, so the wiring in `restoreTimezone` (the `!history` branch, `RecoveryService.swift:196-199`) is untested. Drive it through a recovery whose marker zone differs.
- **M4. `writeFolders` skips a "held" row silently** (`RecoveryWriter.swift:61-62`): no log and no `folderConflicts`. It is unreachable with today's binder. If it is ever reached, the folder's files still carry that path, so `foldersOfAssets` adopts a slot with no `day_place` row, and the slot then gets a bare-date display name. Count and log it like the sharing case.
- **M5. Docs overclaim.** Spec §8.15, `system-architecture.md` (Lost database) and ADR 0028 (Recovery) say "any recovery order" and "files are not adopted". C1 and I2 contradict both. Correct them together with the fixes.

## Verified, no issue

- **Migration `v6-day-place`.** It only adds things, and GRDB runs it in one transaction with the `grdb_migrations` insert, so it is crash-safe and idempotent. `upsert` never writes `place_slot` (tested). There is no `INSERT OR REPLACE INTO asset`.
- **`hasBeenSuperseded` (GRDB 7.12.0).**
  - It returns `[]` when `grdb_migrations` is absent, and false for any prefix of the known migrations. So fresh databases and 0.1–0.3 upgrades open normally.
  - It runs before the FR-52 backup, so the pre-v6 backup is still taken.
  - `DatabaseBackupTests` uses a custom migrator in both open calls, so it is unaffected.
  - `continuous-sources` (`feat/17-dropbox-continuous`, on hold) registers after v6 at merge, and needs no rename.
- **Recovery that already holds up:**
  - R5, an owner-requested recovery with the database intact, binds every folder by remote id with zero moves;
  - R1–R3b and R7 as shipped;
  - E1 with a lost database in a single pass, NAS first: reasoned through, consistent by name.
- **Slot adoption.** It sets both `setPlaceSlot` and `placed.placeSlot` before the target is computed. Primary resource first, then majority, with a tie going to main. `releaseUnconfirmedPlacements` clears `place_slot`.
- **Legacy probes.** The `LegacyLayout` GLOBs and `LegacyRootProbe.isYearFolderName` reject `camera/<day>@…`. The Drive `dayFolder` parses `@slot`, and an invalid slot is not a day folder.
- **Resets.** The timezone restore clears `day_place` and the slots. A factory reset deletes the whole data folder, so `day_place` goes with it. A root change (`resetState`) correctly keeps the global slot state.
- **README.** The "Do not downgrade" note matches the guard's behaviour.

## Unresolved questions

1. For C1: should local recovery wait for an unavailable Drive (deferral), or should slots guessed by a local fallback be marked provisional so that a later Drive pass can rebind them? Deferral is simpler. The provisional approach also covers a Drive added later.
2. For I2: is re-uploading the files of a conflict-dropped folder (duplicate bytes) acceptable to the owner, or should they be adopted with a real parent and moved?

Counts: Critical 1 / Important 3 / Minor 5

Status: DONE_WITH_CONCERNS
Summary: The store migration and the newer-schema guard are sound. Recovery fails its "any order" guarantee: a NAS recovered before Drive makes Drive move every file of a split day into the wrong folders (reproduced twice). The order-sensitive tests do not exercise that order.
