# Verification review: split-day review fixes (#27)

- Branch `feat/27-split-day-by-place` @ `0ca102e`. Fixes reviewed: `git diff 5ace4cd..HEAD` (`e0cd96e`, `ced55e2`). Inputs: `code-review-split-day-engine.md`, `code-review-split-day-recovery.md`, the plan's Decisions.
- How it was checked: two throwaway `git worktree add --detach` copies at HEAD in the session scratchpad, removed afterwards. Probe files `ZZAuditVerifySplit*.swift` (kept in the scratchpad). Mutations were applied with perl, run with `swift test --filter`, and the file restored each time.
- Full suite, 3 runs: **1323 tests / 216 suites**. Run 1 passed (40.3 s), **run 2 failed with 1 issue** (see I3), run 3 passed (36.2 s).
- `xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`: **BUILD SUCCEEDED**. The only warning is the AppIntents metadata notice.

## 1. Status of every finding

"Mutation" means the fix was reverted in the throwaway copy and the named test then failed.

### Engine review
| ID | Status | Evidence |
|---|---|---|
| C1 named → unnamed keeps the name | VERIFIED-FIXED | `update.map(\.name)`. Mutation: `aNamedDayThatBecomesUnnamedLosesItsNameEverywhere` fails (2 issues). The test also checks that a NAS added later gets the bare date. |
| I1 new unnamed extra slot gets no row | VERIFIED-FIXED | `if let previous, …`. Mutation: `anUnnamedExtraGroupGetsItsRowAndTheCountryOnlyFreezeHoldsIt` fails (4 issues). It covers entering and leaving country-only with zero moves. |
| I2 failed rename drops the old name | VERIFIED-FIXED | `reserved` now adds `remote_folder.display_name`. Mutation: `aRenameThatFailedForGoodStillReservesTheNameOnDisk` fails. The test sits at the writer level with a hand-made `failed` job. Side effects are under M-new-1 and M-new-2. |
| M1 `reserved` scans `move_job` | VERIFIED-FIXED | `destination_id IN (SELECT id FROM destination)`. Mutation: the lookup test takes 6.7 s instead of 0.13 s and fails. Its `EXPLAIN` runs on a copied SQL string, not on the production query (see I3). |
| M2 cap applied after a full read | VERIFIED-FIXED | `LIMIT ?` in SQL; nil becomes `-1`, which means no limit. |
| M3 late arrival O(N×M) | VERIFIED-FIXED | Three `LIMIT 1` neighbour queries, as proposed. |
| M4 dirty marks for the whole day | VERIFIED-FIXED | Only the members of the renamed slot are marked. |
| M5 endless slug lengthening | VERIFIED-FIXED | A salt is added past 64 hex digits, with test `lengtheningASlugAlwaysEndsEvenPastTheHashLength`. The old code would hang on that test. I did not run the revert, because it hangs. |
| M6 weak assertions | PARTIAL | Fuzz (d) is replaced by real checks (distinct new slugs, disjoint from existing ones). The perf test now asserts exactly one move per file outside the main folder, and the test names are fixed. `assetSlots.count == members.count` still holds by construction. Harmless. |
| M7 E2 / E19 gaps | VERIFIED-FIXED | E2 now has 40 cells with one uncached cell that is not a representative, and it compares `remote_folder` before and after. The `failed` case is covered by the I2 test. |
| M8 ADR wording | VERIFIED-FIXED | ADR 0028 Grouping bullet and plan Decisions. |

### Recovery review
| ID | Status | Evidence |
|---|---|---|
| C1 NAS before Drive moves Drive files | VERIFIED-FIXED (for the reproduced cases) | Two mechanisms: Drive goes first in `runPending`, and a NAS gets `waitingForDrive`. Mutation with both removed: `r3b…`, `r6…(driveFirst:)`, `r7…` and `aLocalDestinationWaitsWhileDriveIsOfflineThenRecovers` fail (10 issues). Removing only the wait: `aLocalDestinationWaits…` fails. Removing only the ordering: nothing fails, because the wait alone is enough and the ordering only saves a pass. New regressions are I1 and I2 below. |
| I1 phantom order tests | VERIFIED-FIXED | The clock advances between adds, both destinations recover in one pass, Drive is listed by file id plus path, and Drive folder names must be unique. `r6(driveFirst: false)` now fails without the fix, so it is no longer phantom. |
| I2 files of a dropped folder adopted | VERIFIED-FIXED | The binder leaves them out (`compactMap`). Mutation: `filesOfAFolderThatClaimsABoundPathAreNotAdoptedAndStayWhereTheyAre` (through `RecoveryService`) and `twoListedFolders…` fail. |
| I3 `move_job` scan | VERIFIED-FIXED | Same as engine M1. |
| M1 newer-schema message | VERIFIED-FIXED | `AppEnvironment.swift:128`. It compiles in Release. No test, because it is in the app target. |
| M2 dead guard in `inMemory` | VERIFIED-FIXED | Removed. |
| M3 R9 bypassed the wiring | VERIFIED-FIXED | `r9…ThroughRecovery…`. Mutation that drops `clearDayState` from `restoreTimezone`: r9 fails. |
| M4 "held" row skipped silently | VERIFIED-FIXED | It is now counted in `conflicts` and logged. No test (the path is unreachable with today's binder). |
| M5 docs overclaim | VERIFIED-FIXED in docs/ADR/spec | `plan.md:44` and `plan.md:146` still say "any order" (see M-new-4). |

## 2. Probe for (b): names that differ between destinations at the database loss

Setup: the R-world (Đà Lạt 10 = main, Hà Nội 3 = extra; Drive and a real local NAS). Before the loss, one folder was renamed at one destination only, which is what a rename pending at the other one leaves behind. "Moved" means the Drive file's `parentId` changed.

| Case | Drive files moved | Drive-only replay | Duplicate names (Drive / NAS) |
|---|---|---|---|
| One pass (Drive first), **Drive extra folder renamed** ("Hà Nội" → "Hanoi City") | **9 (`gdrive/moveFile` = 9)** | **same: 9, with no NAS at all** | 0 / 0 |
| One pass, NAS extra folder renamed | 0 | n/a | 0 / 0 |
| One pass, Drive main folder renamed | 0 (1 rename) | n/a | 0 / 0 |
| One pass, NAS main folder renamed | 0 | n/a | 0 / 0 |
| NAS alone, Drive added later, Drive extra folder renamed | **9** | n/a | 0 / 0 |
| NAS alone, Drive added later, NAS extra folder renamed | 0 (NAS: 1 rename) | n/a | 0 / 0 |
| NAS alone, Drive added later, **Drive main folder renamed** | **30 of 39** | n/a | 0 / 0 |
| NAS alone, Drive added later, NAS main folder renamed | 0 (NAS: 30 moves) | n/a | 0 / 0 |

No case produced two folders of one day with one name, at either destination.

### Important: I-new-A. A recovered extra folder whose name is out of date makes its whole group move on Drive, even when Drive is recovered first or alone
- **Mechanism.**
  - `RecoveryWriter.adoptSlotFolder` (`RecoveryWriter.swift:97-103`) writes `day_place` with `place_key NULL`.
  - After the loss the geocoder names the group "Hà Nội". Pass 1 (by name) finds nothing. Pass 2 (by key) cannot match a NULL key. Pass 3 fails because the main folder is taken.
  - Pass 4 computes `slug(forKey: "VN|Hanoi")` = `pdcb545ab34e1`. That is **the recovered folder's own slot**, yet it is treated as taken and lengthened to `pdcb545ab34e16928`.
  - Drive-only probe: `day_place = [pdcb545ab34e1 key NULL "Hanoi City", pdcb545ab34e16928 "VN|Hanoi" "Hà Nội"]`, and 9 `moveFile`s go into a new Drive folder "2026-10-23 Hà Nội". "Hanoi City" stays behind, empty, for good.
- **Scope.**
  - This does not come from a local name-order guess, so it falls outside the lead's literal invariant. It does break success criterion 4 (no `move_job` after recovery).
  - Pending renames are not the only trigger. Any change between naming and recovery triggers it: Apple's answers (the 2025 province merger is already in Risks), or an FR-106 refresh. The main folder only gets a rename (pass 3); extra folders move file by file.
  - The bug was already present at `5ace4cd`; neither review caught it. It is not a regression from the fixes.
- **Fix:**
  - In pass 2, also match an unowned slot whose key is nil and whose slug equals `slug(forKey: key, digits: slot.count - 1)`. Drive's `pvLogical` keeps the key-derived slug, so the folder is renamed rather than moved.
  - Alternatively, derive the key at `adoptSlotFolder` time by inverting the slug against the day's group keys.
  - Test: R1 with the Drive extra folder renamed before the loss; assert no `moveFile` and one `renameFolder`.

### Rating of the recorded limit (b): **Minor**, with a larger blast radius than plan.md states
- When Drive is added after a NAS-only recovery and the names differ, up to the **whole main group** moves on Drive (30/39).
  - The Drive main folder ("Lâm Đồng", `pvLogical` = main) loses the main path to the Drive folder that rule 2 bound by name ("Hà Nội" → the NAS's guessed main).
  - It then falls back to `@r…`, and its files follow the database's slot into a new folder.
- No names are duplicated and nothing is lost. The moves are crash-safe `files.update` calls.
- Production reach is low:
  - Drive is mandatory at first start and is created `recoveryRequired` when reused (`AppModel+FirstStart.swift:120-139`), so the NAS waits for it.
  - Reaching the limit takes a "create new" Drive root and then an FR-08 switch to the old root, or Drive data that was not detected while the NAS's data was.
- Recommendation: keep it as a limit. Correct the plan text: "the main group can move", not only the renamed folder.

## 3. Regressions introduced by the fixes

### Important: I-new-1. A NAS waits indefinitely and silently while a flagged Drive cannot recover, and receives no new photos
- **Mechanism.** `RecoveryService.recover` returns `.notReady(.waitingForDrive)` whenever a registered Drive destination has `recovery_required = 1` (`RecoveryService.swift:91-101`). The NAS keeps `recovery_required = 1`, so `acceptsUploads` is false and `EligibilityService.isRecovering` creates no jobs for it.
- **Cases where Drive never clears the flag:**
  - signed out (Drive stays registered, `AppEnvironment.swift:160`);
  - `rootMissing` or `rootTrashed`;
  - permanently offline;
  - a Drive recovery waiting for the owner's decision (`driveNeedsRecovery` ignores `decisionKey`).
- **Owner options.** The owner cannot remove Drive (`removeDestination` guards `.localFolder`).
- **Probe `zzNASWaitsWhileDriveStaysSignedOut`:** Drive is flagged and signed out, and a new photo is added. After about 30 settle rounds and 5 h of harness time:
  - `nasRecoveryRequired=true`, `nasStatus=active`, **0 NAS jobs** (the new photo is not queued);
  - **no NAS activity row at all**;
  - a manual NAS recovery returns `waitingForDrive`.
  - The NAS row reads "active" while it backs up nothing.
- **Before the fixes,** the NAS recovered on its own and resumed. Data at the destinations is safe, but the second copy of new photos silently stops. That matters for a backup app.
- **Fix (options for the lead; the trade-off is the C1 guess):**
  1. Do not wait while Drive is `paused(signedOut/rootMissing/rootTrashed)` or `decisionKey` is set; wait only while Drive is reachable or transiently offline. Optionally add a time bound (for example 24 h), after which the local guess is used and an activity notice says so.
  2. In every case, write a one-time activity notice for the NAS ("Waiting for Google Drive to be recovered first") and show it on the destination row.
  - Test: Drive flagged and signed out; the NAS must either recover or show the notice, and a new photo must reach the NAS once the policy allows.

### Important: I-new-2. First start fails when Drive's recovery cannot finish
- **Mechanism.**
  - `AppModel+FirstStart.recoverReusedDestinations` (`AppModel+FirstStart.swift:172-193`) recovers `[.googleDrive, nas]`.
  - When Drive returns `destinationUnavailable`, `cloudIdsPending` or `needsOwnerDecision`, the code continues to the NAS. The NAS then returns `.notReady(.waitingForDrive)`.
  - That case is not in the catch list (only `alreadyRunning`, `destinationUnavailable`/`cloudIdsPending` and `needsOwnerDecision` are), so it propagates.
- **Effect.**
  - `performFirstStart` sets `firstStart.failure`, the "upload" phase is never reached, and the window reports a failed start.
  - In fact the engine would recover the NAS automatically once Drive is done.
- **Reach.** It happens with Drive reuse plus NAS reuse and either a transient Drive outage during onboarding or a Drive match ratio below 50%.
- **Fix:** add `.waitingForDrive` to the "continues automatically" catch.
  - `addLocalDestination` has the same gap (`AppModel+Destinations.swift:113-116`). The destination is already committed, yet the owner sees an error that says "Try again once Drive has finished". The text should say recovery will continue by itself.

### Important: I3. `lookingUpOpenRenamesStaysFastOverHundredThousandFinishedMoves` is flaky
- **Evidence.** Full-suite run 2 failed at `SplitDayPerformanceTests.swift:105`: `elapsed 3.64 s < 2 s`. The same test took 0.13 s and 0.16 s in runs 1 and 3. A synchronous test under the parallel suite gets descheduled, so CI will go red at random.
- **Phantom check.** The `EXPLAIN` asserts on a hand-copied SQL string, so a change to `DaySplitWriter.reserved` would not trip it. Only the timing catches it (6.7 s vs 0.13 s with the filter removed).
- **Fix:** keep the 10 s bound used by the other perf tests. For the index check, use `EXPLAIN` on a SQL constant that `reserved` itself uses, or count `sqlite3` VM steps.

### Minor
- **M-new-1. `reserved` now scans `remote_folder` in full.**
  - `SELECT display_name FROM remote_folder WHERE logical_path = ?` (`DaySplitWriter.swift:93`) cannot use the PK `(destination_id, logical_path)`.
  - sqlite3 probe with 20k rows: `SCAN remote_folder`, and 3,000 lookups take **1.16 s**. The `destination_id IN (SELECT id FROM destination)` form gives `SEARCH … USING INDEX` and **0.005 s**.
  - It runs per slot per evaluated day (upgrade backfill, inside the `PlaceNamer` write) and twice per slot in `knownSlots`.
  - Use the same `destination_id IN` filter.
- **M-new-2. A rename that failed for good now blocks a group named like the old name, for good.** No code path retries a `failed` move job (only `inProgress → pending` at startup). The group stays in `deferredGroups`, and the day is re-marked dirty on every evaluation with no owner-visible state. This is the intended trade-off against two folders with one name. Record it in the plan, or offer a retry for failed moves.
- **M-new-3. The ordering in `runPending` is untested.** It is redundant with the wait, so behaviour stays correct without it (mutation: no test fails); it only saves a pass. Fine as is; noted so nobody counts on it as the guard.
- **M-new-4. Docs.**
  - `system-architecture.md` (Lost database) now reads "…can only guess which folder of a split day is the main one: by the id of an existing `remote_folder` row, …". The colon attaches the binding rules to the guess clause.
  - Neither the architecture doc nor spec §8.15 mentions that the wait has no bound (I-new-1), or the limit that an undetected Drive is not waited for.
  - `plan.md:44` and `plan.md:146` still say "any order".
- **M-new-5. The activity text for a writer-held row says "its files are untouched".** On that (unreachable) path the files are still adopted. Either adjust the text or drop the files there too.

## 4. Checks
- Full suite x3: pass / **fail (I3 flake)** / pass; 1323 tests each.
- Release xcodebuild unsigned: BUILD SUCCEEDED.
- Mutations: 9 run. Each fixed Critical and Important finding is caught by at least one test, except the redundant ordering (M-new-3).
- Probes: 8 drift cases, 1 Drive-only drift, 1 signed-out wait, plus the sqlite3 cost probe.

## Recommended actions
1. I-new-1: decide the wait policy (which Drive states to wait for, and a bound), then add a NAS activity notice.
2. I-new-2: catch `.waitingForDrive` in first start and in add-destination, with "continues automatically" text.
3. I-new-A: let pass 2 match a key-less slot by its key-derived slug, and add the drifted-name R1 test.
4. I3: loosen the timing bound, and run `EXPLAIN` on the production SQL.
5. M-new-1: add the `destination_id IN` filter to the `remote_folder` lookup.

## 5. Addendum: commit `4280603` (rebinding a local recovery's guessed slots to Drive's)

Reviewed at the committed `4280603` only. The branch worktree has uncommitted changes from someone else (`RecoveryService`, `AppModel+FirstStart`, `SplitDayRecoveryWaitTests.swift`, …); they are not part of this review.

**Checks at `4280603`.** The throwaway worktrees were removed afterwards.
- Full suite x3: **1325 tests, pass / pass / pass**.
- The flaky lookup test took 0.10 s, 0.19 s, then **1.59 s** against its 2 s bound (run 3 shared the machine with the Release build). I3 stays open.
- Release xcodebuild unsigned: **BUILD SUCCEEDED**.
- Mutations: disabling `resolve`, the name-binding skip for provisional days, or `guessed` marking makes both new recovery tests fail; `localFallbackBindingsAreMarkedAsGuesses…` also fails on the third.

**What holds.**
- **Crash safety.** `ProvisionalSlots.resolve` runs in one `store.write` transaction that also clears the flags, so it applies fully or not at all.
  - A crash after it commits but before Drive's `finish` reruns Drive with no provisional days. Rule 2 (by name) then binds against the rebound slots, whose names now equal Drive's, so the result is the same.
  - `mark` is a separate, idempotent write before `writeFiles`.
- **Swaps.** The two-phase `tmp:` rename handles chains and swaps.
  - Probe: the NAS guessed main = "Hanoi City" and `@r` = Đà Lạt; Drive has main = Đà Lạt and `@p` = Hà Nội.
  - Rebinding maps main → `@p` and `@r` → main. Rows, `upload_job` parents and asset slots all follow, and no Drive file moves.
- **In-flight work.**
  - Uploads and moves do not overlap a recovery: the cycle runs `runPending` before its passes, owner commands go through the lane, and upload task groups are awaited within a pass.
  - Pending `moveFile` jobs heal themselves, because `MoveWorker` takes `from` from the rebound `remote_logical_parent` and recomputes the target.
  - `FolderEnsurer` reads `remote_folder` on every call, so no cached path goes stale.

### Important: I-new-3. A pending NAS rename hits the wrong folder after rebinding, and the wrong name stays for good
- **Cause.** Rebinding rewrites `remote_folder`, `upload_job`, `asset`, `day_stat` and `day_place`, but **not `move_job`**. `MoveWorker.renameFolder` looks the folder up by `move.subject` (a logical path) and never checks that the folder still carries `from_value`.
- **Probe `zzPendingNASRenameDuringRebind`:**
  1. The NAS shows "Hanoi City" before the loss.
  2. The NAS is recovered alone, owner-paused, so its rename stays pending: `renameFolder camera/<day> "… Hanoi City" → "… Hà Nội"`.
  3. Drive is recovered, and `camera/<day>` at the NAS now means the Đà Lạt directory.
  4. The NAS is resumed.
- **End state:**
  - the NAS folder **"2026-10-23 Hà Nội" holds the 30 Đà Lạt files**, and "2026-10-23 Hanoi City" holds the 9 Hà Nội files;
  - the database says main = Đà Lạt and `@p` = Hà Nội, so no corrective rename is ever queued, because `name != stat.placeName` is false;
  - the main row's `display_name` "Hà Nội" is now reserved for main, so the Hà Nội group is deferred on every evaluation.
- **Impact.** Drive is untouched and no file is lost. But the NAS backup is mislabeled permanently, which is exactly what this commit is meant to prevent.
- **When it happens.** It needs an open rename (pending, or `inProgress` reset to pending at launch) at the NAS when Drive is recovered. That happens when the NAS was offline or paused, or its rename was still retrying. The namer queues such renames right after a NAS-only recovery whenever names drifted.
- **Fix:**
  - apply the same two-phase mapping to `move_job.subject` of open `renameFolder` jobs, and to `from_value` of open `moveFile` jobs, inside the same transaction;
  - also make `renameFolder` discard a job whose `folder.displayName != move.fromValue`. That cheap invariant also protects every other path that relabels rows.
  - Test: the probe above, asserting that each NAS folder's name matches its contents.

### Minor
- **M-new-6. Rebinding happens before the owner-decision guard.** `resolve` runs before `RecoveryMatcher` and the 50% match check (`RecoveryService.swift:149-154`).
  - Probe `zzRebindBeforeOwnerDecision` (60 unknown files at Drive): Drive ends in `recoveryNeedsDecision`. Yet the NAS rows were already rewritten (`camera/<day>` went from "Hà Nội" to "Đà Lạt", `@r…` became `@p…`) and the provisional flags were cleared.
  - The guard exists for a root that may not be this library's. If the owner then picks "continue without the old data", the NAS has still been relabeled from that listing.
  - Move `resolve` after the guard (just before `writeFolders`); the binding is already computed.
- **M-new-7. The docs overclaim, and question 2(b) is still a limit.**
  - In the drift probes at `4280603`: Drive added later with the Drive extra folder renamed still gives **9 Drive moves**, and with the Drive main folder renamed still **30**. That is unchanged from before the commit, because `rebind` maps by display name only. One-pass drift (I-new-A) still gives 9 moves.
  - `plan.md` says "Drive files never move". `system-architecture.md` says "so no Drive file moves", and that sentence also lacks a period before "A local recovery…".
  - The plan's "Known limit" line does not say that Drive files then move (up to the whole main group).
  - Fix: map each Drive folder to the current slot holding most of the assets whose matched Drive files sit in it. The matcher already has asset → Drive file → parent. This is name-independent, closes 2(b), and makes the main-folder case keep the main folder.
- **M-new-8. Provisional flags outlive their meaning.**
  - `guessed` is set whenever a local folder falls back, even after Drive was already recovered (one-pass drift), and `clearDayState` (timezone restore) does not clear the flags.
  - A later owner-requested Drive recovery then skips name binding for those days and runs `resolve`. That is harmless today because rule 1 (by remote id) wins, but it is unexpected.
  - Phase 2 can also violate the `(destination_id, logical_path)` PK if a destination has a row on a target path outside `current`, which takes a row with no `day_stat`/`day_place` entry. The whole Drive recovery would then fail every cycle as `destinationUnavailable`. That is theoretical; compute the moved set over `remote_folder` paths too, or log and skip.

### Status of 2(b) after `4280603`
**Partly covered.**
- Covered: the name-order guess when names agree (main/extra swap). Both new tests and my swap probe show zero Drive moves.
- Not covered:
  - names that differ between destinations: Drive moves 9 or 30 (M-new-7);
  - names that differ from the current geocode with Drive first: I-new-A, unchanged.
- No duplicate folder names in any case.
- New hazard: a pending NAS rename lands on the wrong folder (I-new-3).

### Earlier findings at `4280603`
I-new-1, I-new-2, I-new-A, I3 and M-new-1 to M-new-5 are unchanged in the committed code (the signed-out and drift probes repeat their results).

## Unresolved questions
1. I-new-1: should a NAS wait for a Drive that is signed out or awaiting the owner, and for how long? Waiting protects Drive from following a local guess (C1). Not waiting keeps the NAS backing up. This is the lead's or the owner's call.
2. I-new-A is a pre-existing gap found by the requested probe. Fix it in this branch, or record it as a known limit next to (b)?
3. I-new-3: remap open move_job subjects in the rebinding transaction, or also add the from_value guard in MoveWorker (recommended: both)?

Counts: Critical 0 / Important 5 / Minor 9

Status: DONE_WITH_CONCERNS
Summary (updated for 4280603): rebinding fixes the name-order guess when names agree and is crash-safe, but it leaves open renames on stale subjects, so a NAS folder can end up permanently mislabeled (I-new-3), and 2(b) with differing names is still a limit. Earlier summary: Every Critical and Important finding from both reviews is fixed, and reverting each fix makes a test fail. The new Drive-recovery wait silently stops NAS backups while a flagged Drive cannot recover, and it breaks first start when Drive's recovery has to wait. Probe (b) found Drive moving a whole extra group after a recovery whose folder name is out of date, even with Drive recovered first or alone.
