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

Counts at 4280603: Critical 0 / Important 5 / Minor 9

Status at 4280603: DONE_WITH_CONCERNS
Summary (updated for 4280603): rebinding fixes the name-order guess when names agree and is crash-safe, but it leaves open renames on stale subjects, so a NAS folder can end up permanently mislabeled (I-new-3), and 2(b) with differing names is still a limit. Earlier summary: Every Critical and Important finding from both reviews is fixed, and reverting each fix makes a test fail. The new Drive-recovery wait silently stops NAS backups while a flagged Drive cannot recover, and it breaks first start when Drive's recovery has to wait. Probe (b) found Drive moving a whole extra group after a recovery whose folder name is out of date, even with Drive recovered first or alone.

## 6. Final verification at `54ee60b` (`b7ee303`, `54ee60b`)

**Checks.** Throwaway worktrees at `54ee60b`, removed afterwards. Probe file `ZZAuditFinal.swift` is in the session scratchpad.
- Full suite x3: **1339 tests, pass / pass / pass**.
- The lookup test took 2.74 s, 0.14 s and 0.16 s. Run 1 would have failed the old 2 s bound; the new bound is 10 s.
- Release xcodebuild unsigned: **BUILD SUCCEEDED**.

### Status of the open findings
"Mutation" means the fix was reverted in the throwaway copy and the named test then failed.

| Finding | Status | Evidence |
|---|---|---|
| I-new-1 NAS waits silently and with no limit | VERIFIED-FIXED | The NAS no longer waits for a Drive that is stalled (signed out, root problems, `userPaused`) or awaiting an owner decision, and waits at most 30 min otherwise. It shows `paused(waitingForDrive)` plus one activity row. Mutations: drop the stalled skip, then `aLocalDestinationDoesNotWaitForADriveThatIsSignedOut` fails; drop the decision skip, then `…AwaitingTheOwner` fails; drop the time bound, then `…ForHalfAnHourAndShowsWhy` fails. Probe `zzSignedOut`: the NAS recovers alone, and the new photo is `done` at the NAS (3 files). Probe `zzOfflineWait`: `paused(waitingForDrive)`, then the NAS recovers alone after 35 min of harness time. |
| I-new-2 first start / add folder fail on `waitingForDrive` | VERIFIED-FIXED (code only) | Both catch sites now treat it as "continues by itself", with new text. The app target has no unit test; it compiles in Release. |
| I-new-3 pending NAS rename hits the wrong folder | VERIFIED-FIXED | Open `move_job`s are remapped in the rebinding transaction, and `MoveWorker` discards a rename whose `fromValue` is not the folder's name. Mutations: drop the remap, then `aRenamePendingAtTheNASFollowsItsFolderThroughTheRebind` fails; drop the guard, then `aRenameQueuedForAnotherNameThanTheFolderCarriesIsDiscarded` fails. Probe `zzPendingRenameRebind`: the NAS ends with "Hà Nội: h=9" and "Đà Lạt: d=30", and no Drive file moves. |
| I-new-A drifted extra folder emptied by 9 Drive moves | VERIFIED-FIXED | Pass 2 matches a key-less `p…` slot by its key slug. Mutation: `aFolderRecoveredWithoutAKeyIsRenamedWhenItsSlugIsTheGroupsOwn` and `aRenamedExtraFolderOnDriveIsRenamedNotEmptied` fail. Probe `zzDriveOnlyDrift`: 0 Drive moves, 1 rename. |
| I3 flaky lookup test, `EXPLAIN` on copied SQL | VERIFIED-FIXED | `EXPLAIN` now runs on `DaySplitWriter.openRenamesSQL` and `folderNamesSQL`, with a 10 s bound. Mutation: drop the filter from `folderNamesSQL`, then the test fails at once (0.36 s, on the plan assertion). |
| 2(b) names that differ at the loss | VERIFIED-FIXED for Drive; see I-new-B for the NAS | All 8 drift cases (extra or main folder renamed, at Drive or at the NAS, one pass or Drive added later) plus Drive-only: **0 Drive file moves and 0 duplicate Drive names**. A drifted Drive name is fixed with one `renameFolder`. Mutations: disable the membership mapping, then `aRenamedExtraFolderOnDrive…` and `aRenamedMainFolderOnDrive…` fail; disable `renameDriftedFolders`, then both fail too. |
| M-new-1 `remote_folder` scan | VERIFIED-FIXED | It now uses the destination filter (same mutation as I3). |
| M-new-2 permanent deferral after a rename that failed for good | VERIFIED (accepted, documented) | Recorded in plan Decisions. |
| M-new-3 ordering untested | VERIFIED (documented) | Recorded as an optimisation. |
| M-new-4 docs | VERIFIED-FIXED | The architecture sentence is fixed, the wait and its bound are documented, and `plan.md` no longer says "any order". |
| M-new-5 activity text | VERIFIED-FIXED | The "its files are untouched" claim is gone. |
| M-new-6 rebinding before the match guard | VERIFIED-FIXED | Mutation-free evidence: test `nothingIsReboundWhileDrivesRecoveryAsksTheOwner`, and probe `zzRebindBeforeDecision` (rows unchanged, days stay provisional, 1 decision). |
| M-new-7 docs overclaim | PARTIAL | The Drive claims are now true. The recorded conflict limit understates its effect (see I-new-B). |
| M-new-8 stale flags, PK collision | VERIFIED-FIXED | No flags once Drive is recovered (`aFolderGuessedAfterDriveWasRecoveredIsNotProvisional`); a timezone restore clears them; a PK clash leaves the day provisional. Mutation: drop the PK check, then `aRowOutsideTheRebindOnATargetPathLeavesTheDayAlone` fails. |

**Correction to section 2.** The table there reported 0 Drive moves for "one pass, NAS extra folder renamed", which is right. But that probe never checked the NAS's own recovery state, and the NAS had ended in an owner decision (see I-new-B). That path is unchanged since `5ace4cd`, so it was probably already true then.

### Rebinding and remap: regressions hunted
- **Crash between the phases.** None is possible: both phases, the asset slots, `day_stat`/`day_place` and the `move_job` remap are one `store.write`.
- **A move interrupted by a crash (`afterMoveStarted`/`afterMoveBeforeCommit`) and then rebound before it reruns.**
  - The rebinding applies one mapping to the folder rows, `remote_logical_parent`, `place_slot` and `move_job.from_value`/`to_value`, so each logical path still names the same physical folder.
  - `MoveWorker` takes `from` from the rebound parent and recomputes the target from the rebound slot. The replay is the same operation as without the rebinding, so no new idempotency case appears. This is reasoned from the code, not probed with a crash point.
- **Membership mapping.**
  - It counts `upload_job` rows with a remote id for the day across destinations; Drive has no jobs yet at that point.
  - It is greedy by shared count, with a lexicographic tie-break. Names come second.
  - No case in 8 drift probes plus 3 tests mislabeled a folder or moved a Drive file.
- **Rename discard: see M-new-9.**

### Important: I-new-B. A local folder with an out-of-date name, recovered after Drive (the default order), either blocks the NAS behind an owner decision or silently duplicates a group into a mislabeled folder
This is the developer's recorded limit. In my judgement it is **not acceptable for release** as recorded.
- **Mechanism.** `DaySlotBinding.bind` binds the folders of a day one by one, sorted by collision key.
  - A folder whose name no known slot carries ("Hanoi City", which sorts before "Đà Lạt") takes the fallback first. On a local destination that means `camera/<day>` while it is still free.
  - The folder that really is the main one ("Đà Lạt", known by name) then finds its path bound and is **dropped as a conflict**.
- **Two-province probe (`zzOnePass` nasExtraRenamed and driveExtraRenamed).**
  - Drive moves nothing, but the NAS ends in `paused(recovering)` with `recoveryNeedsDecision`: 9 of 39 matched, and NAS backups are held.
  - In the NAS-renamed variant, "Try again" can never succeed, because the NAS folder keeps its name. "Continue without the old data" re-uploads all 39 files next to the existing ones.
- **Three-province probe (`zzConflictWithThreeProvinces`; Đà Lạt 10 main, Bắc Ninh 9, Hà Nội 3; the NAS's Hà Nội folder is "Hanoi City").** The dropped group is under 50%, so the recovery goes on with only the activity row "1 folder claimed a path… left out".
  - The NAS ends with `Hanoi City: d=30` (**the 30 Đà Lạt files uploaded again, into a folder named "Hanoi City"**), `Đà Lạt: d=30` (the originals, now untracked), `Hà Nội: h=9` (9 NAS moves out of "Hanoi City") and `Bắc Ninh: b=27`.
  - That is 96 files where there were 66. The main row is named "Hanoi City" while the database says Đà Lạt, and no rename is ever queued.
  - The recorded limit's "Nothing is moved or lost" does not hold for this case. Nothing is lost, but files move at the NAS, bytes are duplicated, and a backup folder is permanently mislabeled.
- **Trigger.** A NAS folder name that differs from Drive's at the loss: a rename still pending at the NAS, or a name done at the NAS only. That is exactly 2(b), in the default Drive-first order.
- **Fix (small, inside `DaySlotBinding`):**
  1. Bind every folder of a day by id and by name first, then run the fallback for what is left.
  2. A local fallback never takes the path of a known slot; use `@r…` instead. The namer and membership then settle it, at worst with NAS-only moves.
  3. Optionally, before the fallback, bind an unknown local folder to the known slot that holds most of its files' assets (the fingerprint names give the asset keys). That makes it a zero-move case.
  - Tests: both probes above. Assert no conflict, no owner decision, an unchanged file count at the NAS, and folder names that match their contents.

### Minor
- **M-new-9. A chained rename after a transient failure ends on the older name, for good (already so before the guard).**
  - `MoveWorker` handles `.retry` with `continue`, so the second rename of the same folder (B → C, queued with `fromValue` B) runs in the same pass while the folder is still A.
  - The guard discards it, then the first rename succeeds on retry. Probe `zzChainedRenameAfterTransientFailure`: the Drive folder and the row end at "B", and both jobs are `done`.
  - Without the guard the result was B as well (A→C, then C→B), so this is not a regression of the outcome. What changed: if the first rename failed for good, the second used to heal it (A→C) and is now discarded.
  - Nothing reconciles a row's `display_name` with its slot's name afterwards.
  - Fix: keep renames in order per subject within a pass (stop that subject's later jobs on `.retry`). Optionally, after the moves, queue a rename for any row whose name differs from its slot's name and that has no open or failed rename.
- **M-new-10. `paused(waitingForDrive)` can outlive the wait.** `DestinationHealth` skips that status, and only `enter()` or `finish()` replace it.
  - If the wait ends (time limit, or Drive stalls) while the NAS is itself unreachable, the NAS row keeps saying "waiting for Google Drive recovery" until the NAS comes back.
  - Likewise, an owner resume during the wait shows "active" while it still waits (at most 30 min).
  - Cosmetic. Set the status back when `mustWaitForDrive` returns false.
- **M-new-7 (PARTIAL, above).** The architecture doc, ADR and plan "Known limit" describe the conflict as "asks the owner; nothing is moved or lost". Correct the text together with the I-new-B fix, or describe the duplicate-upload outcome if the fix is deferred.

### Merge readiness
**Not ready to merge as is.** Every finding from the earlier rounds is fixed, and the Importants are mutation-proven. Drive files never move in any of the probed orders. One Important remains: I-new-B sits in the default recovery order. Its worst case puts duplicate bytes into a permanently mislabeled NAS folder without asking the owner; its common case leaves the NAS held behind an owner decision that "Try again" cannot clear.
- The fix is local to `DaySlotBinding`: two passes, and no known slot path in the fallback. With it and the two probe tests, I would call the branch ready.
- If the lead accepts I-new-B as a known limit for this release instead, then M-new-7 must at least be corrected, so the docs do not promise "nothing is moved". The branch is otherwise mergeable, and M-new-9/10 can follow.

Counts at 54ee60b: Critical 0 / Important 1 / Minor 3

Status at 54ee60b: DONE_WITH_CONCERNS
Summary at 54ee60b: All earlier findings are fixed or documented, the Importants are proven by mutation, and Drive files no longer move in any of the 8 drift probes. One Important remains in the default Drive-first order (I-new-B): a local folder with an out-of-date name makes the binder drop the real main folder, which either holds the NAS behind an owner decision or re-uploads that group into a mislabeled folder. The fix is small; not ready to merge until it is fixed or explicitly accepted.

## 7. Delta verification at `528d549`

**Scope.** I-new-B, M-new-9, M-new-10 and M-new-7, plus a regression hunt around binding by the sidecar `claimedKey`.

**Checks.**
- Full suite once: **1345 tests passed** (44.2 s).
- Release xcodebuild unsigned: **BUILD SUCCEEDED**.
- Throwaway worktrees were removed afterwards. Probe files `ZZAuditDelta.swift` and `ZZAuditFinal.swift` are in the session scratchpad.

| Finding | Status | Evidence |
|---|---|---|
| I-new-B unknown-name local folder drops the real main folder | VERIFIED-FIXED | `DaySlotBinding` binds by id and name for all folders first, then by contents, then falls back, and the fallback never takes a known slot path. **Cross-version check:** the 4 new tests, run against the `54ee60b` sources, fail (`aLocalFolderWithAnOldNameIsRecoveredAfterDriveWithoutAnOwnerDecision`, 3 issues; `…DoesNotUploadAGroupAgainWithThreeProvinces`, 1 issue); at `528d549` they pass. Mutation: disable the by-contents step, then `anUnknownLocalFolderTakesTheKnownSlotHoldingItsAssets` fails. My probes: two provinces gives **no owner decision**, no conflict, 0 Drive moves, and the NAS ends with "Hà Nội: h=9", "Đà Lạt: d=30" (one NAS rename). Three provinces gives **66 files (no duplicates)**, no conflict row, and folders named after their contents. |
| M-new-9 chained renames after a transient failure | VERIFIED-FIXED | A retried rename holds back the later renames of that folder in the pass. Mutation: drop the hold-back, then `chainedRenamesOfOneFolderRunInOrderEvenAfterATransientFailure` fails. Probe `zzChainedRenameAfterTransientFailure`: the folder and row end at "C", as intended (it was "B" at `54ee60b`). |
| M-new-10 `waitingForDrive` outlives the wait | VERIFIED-FIXED | `endWait` restores the owner's status. Mutation: make `endWait` a no-op, then `theWaitingStatusEndsWithTheWaitEvenIfTheDestinationIsOffline` fails; that test also fails on the `54ee60b` sources. |
| M-new-7 docs | VERIFIED-FIXED | The architecture doc, ADR 0028 and the plan now describe the remaining limit accurately: no sidecar-identified asset means a `@r…` guess, and the files may move at that destination, never at Drive. That matches the JSON-off probe below. |

**Regression hunt: binding by `claimedKey`.** All variants run in one pass with Drive first, and the NAS's Hà Nội folder renamed to "Hanoi City".
- **JSON sidecars off** (two and three provinces):
  - No `claimedKey`, so the folder falls back to `@r…`. The NAS moves 6 files into a new "Hà Nội" folder, and the empty "Hanoi City" stays, because emptied folders are never deleted (§8.7.4).
  - **No Drive file moves.** The extra Drive files are JSON sidecars uploaded anew, because the settings were in the lost database and default back to on. They are not moves.
  - No duplicate names and no decision. This is the documented limit.
- **A folder holding files of two slots** (2 Đà Lạt assets left in "Hanoi City" from a half-done move): the majority (Hà Nội) wins. The 6 Đà Lạt files move back to the main folder at the NAS, the folder is renamed, and no Drive file moves.
- **Sidecars of assets deleted from Photos** (all Hà Nội photos deleted before the loss): no claimed key resolves, so the folder falls back to `@r…` and keeps its files (T23). Nothing moves anywhere, and there is no conflict.
- **`assetSlotPaths` keys by the raw `asset_key`.** A sidecar that claims an alias key (`h:` prefix, or a local id that changed on a new Mac) is not counted, so that folder degrades to the same `@r…` guess, with NAS-only moves. Acceptable.

### Minor
- **M-new-11. The "fallback never takes a known slot path" guard (`!owned.contains(preferred)`) is untested.**
  - Mutation: remove it, and all 41 binding and recovery tests still pass. With the two-phase order, the main path is normally already bound by name before any fallback runs.
  - The guard only matters when the main folder is absent at that destination (R7-like rules) and an unknown-name folder is present.
  - Add one `DaySlotBindingTests` case: known main plus an extra slot, the NAS listing has only an unknown-name folder, and its path must not be `camera/<day>`.

### Merge readiness
**Ready to merge: yes.** No Critical or Important finding is open. Every Important from all rounds is proven fixed, either by mutation or by running the new tests against the previous sources. Drive files did not move in any probed recovery order or drift case. M-new-11 is a missing test, not a defect, and M-new-2 (permanent deferral after a rename that failed for good) is an accepted, documented trade-off.

Counts (final, at 528d549): Critical 0 / Important 0 / Minor 1

Status: DONE
Summary (final): I-new-B, M-new-9, M-new-10 and M-new-7 are fixed and proven by mutation or by the new tests failing on 54ee60b. The claimedKey binding degrades safely without sidecars, with NAS-only moves and never Drive moves. The branch is ready to merge; one Minor (an untested guard) can follow.
