# Code review: split-day engine, policies and moves (#27)

- Branch `feat/27-split-day-by-place` @ `5ace4cd`, diff `origin/release/0.4.0...HEAD`
- Scope: PlaceSplitPolicy, DaySlotPolicy, DynamicLayout slot paths, PlaceNamingPolicy, PlaceNamer, DaySplitWriter, upgrade/hidden backfill, country-only freeze, deferred groups, MoveWorker cap and crash points, late arrivals, LayoutResolver call sites, views. Recovery and the store migration are out of scope.
- Full suite in a throwaway worktree: **1315 tests in 216 suites passed** (35.9 s).
- Probes: throwaway worktree, files `ZZAudit*.swift`, results quoted below. The worktree was removed afterwards. Probe sources are in the session scratchpad.

## Critical

### C1. A named main folder no longer loses its name: `writeMain` treats "group is unnamed" as "no update"
`Sources/PhotoVaultEngine/DaySplitWriter.swift:56`: `let name = update?.name ?? stat.placeName`. When the main slot is assigned an **unnamed** group, `update.name == nil` and `??` falls back to the old name. The key line just below (`update.map(\.key) ?? …`) gets this right.

- **Effect on one-province days (regression from 0.4.0, breaks success criterion 2):** take a named day plus a photo about 950 km away in a sea cell. The box is over 300 km and at most one province is known, so the result is `unnamed`. 0.4.0 renames the folder to the bare date. Probe `zzNamedDayBecomesUnnamed`:
  - `day_stat` = `state unnamed, key nil, name "Đà Lạt"` (inconsistent);
  - no rename is queued; Drive keeps `2026-10-23 Đà Lạt`;
  - a NAS added afterwards creates `2026-10-23`, because `LayoutResolver` uses the name only for `named`/`waitingGeocode`.

  The two destinations now disagree, and nothing ever reconciles them.
- **The same happens in country-only mode** for unsplit days (two country-level identities give `unnamed`); probe A shows `placeKey nil, placeName "Las Vegas", unnamed`.
- **Knock-on:** the slot name index keys the main folder by the stale name. An unnamed group later gets a new `p…` folder showing the bare date, while a destination that created the main folder after the stale state also shows the bare date. That gives two logical folders with one name, and on a local destination `ensureFolder` adopts the same directory.
- **Why no test caught it:** the only engine test of named → unnamed (old `t28…DropsAnExistingName`) was rewritten into the split test.
- **Fix:** `let name = update.map(\.name) ?? stat.placeName`. Add an engine test: a named one-province day becomes unnamed, gets a `renameFolder` to the bare date, and a NAS added afterwards has the same name.

## Important

### I1. A new unnamed extra folder never gets its `day_place` row
`DaySplitWriter.swift:31`: `if previous?.placeKey == update.key && previous?.placeName == update.name { continue }`. For a **new** slot `previous` is nil, so for an unnamed group (key nil, name nil) both sides are `nil == nil` and the row is skipped. The assets still get the slot `p` + sha256("") (`pe3b0c44298fc`).

- **Reachable** with two provinces where one group's box is over 300 km while the main folder is already named, for example a Nevada day named "Las Vegas" plus late photos from San Diego and Redding.
- Probe `zzUnnamedExtraGroupRowAndCountryOnly`: `rows=[]`, `slotS=pe3b0c44298fc`, `DayPlaceRepository.exists == false`, folders `["… Las Vegas", "…"]`.
- **Consequences:**
  - The country-only freeze checks `exists(day)`, so the day is **not frozen**. Entering country-only moved every California file back to the main folder (moveFile 8 → 32), and leaving moved them out again (32 → 56). That is the double mass move the freeze decision was meant to prevent.
  - The late-arrival guess is skipped (`exists` is false).
  - Recovery binding by display name cannot see the slot.
  - The slot is missing from `slots`, so its bare-date name is not in the name index.
- **Fix:** `if let previous, previous.placeKey == update.key, previous.placeName == update.name { continue }`. Add a policy/engine test with an unnamed group that lands in a new extra slot.

### I2. A rename that failed for good leaves its old name on disk but drops it from the name index
`DaySplitWriter.reserved` (`:80-89`) reserves only the `from_value` of **pending/inProgress** renames. After more than 8 failures a move job is `failed` (`FolderAndMoveRepositories.swift:87-93`). On a local destination this happens for good when the target name exists (`renameExclusive`), and also on repeated I/O or permission errors. The folder keeps its old name on disk, and `remote_folder.display_name` also keeps it, but the policy forgets the name.

- Probe `zzFailedRenameNameNotReserved`: the main folder was renamed to "Hanoi City", done on Drive and **failed** on the NAS, so the NAS still shows `… Hà Nội`. A group named "Hà Nội" then arrives. Result: `needsRetry=false`, and the extra slot gets a pending `renameFolder … Đà Lạt -> … Hà Nội` at the NAS, a name already held there by the main folder.
- **What happens next:** a local rename fails as well. If the group needs a new slot instead, `FolderEnsurer` creates `… Hà Nội`, and `LocalFileOps.ensureFolder` (`:97-111`) adopts the existing directory. Two `remote_folder` rows then share one directory. A later rename of either rebases the other's paths, leaving orphaned or missing files and re-uploads. This is the exact hazard the ADR says cannot happen.
- **Likelihood:** low (it needs a failed rename), but the impact touches backed-up files.
- **Fix:** for each slot path, also reserve the `display_name` of its `remote_folder` rows at every destination when it differs from the slot's name (strip the `YYYY-MM-DD ` prefix). That covers failed renames and any other drift. Test: a failed NAS rename followed by a group with the old name, which must be deferred.

## Minor

- **M1. `reserved` scans `move_job` in full.** `WHERE subject = ? AND op … AND state …` has no `destination_id`, so the new index `move_job(destination_id, subject)` cannot be used. Done jobs are never pruned (there is no `DELETE FROM move_job`). It runs once per slot per evaluated day, for example about 3,000 days times the full table during the backfill. Fix: loop over `context.destinations` with `destination_id = ?`, or add an index on `(subject, op, state)`.
- **M2. `MoveWorker` reads every pending row, then applies `.prefix(cap)`** (`MoveWorker.swift:58`). Across an upgrade backlog that decodes the full queue on every pass. Put the limit in the SQL (`ORDER BY id LIMIT ?`).
- **M3. The late-arrival guess costs O(N×M).** `slotForLateArrival` (`AssetFinalizer.swift:37-51`) loads every camera row of the day for each newly placed asset. An import of 2,000 files into a split day of 2,000 photos decodes about 4M rows inside the scan transaction. Fix: query the two neighbours with `ORDER BY creation_date` and `LIMIT 1` on either side.
- **M4. Too many assets marked dirty on an extra-slot rename.** `DaySplitWriter.swift:36` marks the members of **every** group dirty, not just that slot's members, so sidecars, views and descriptions are recomputed for the whole day.
- **M5. Slug lengthening never terminates past 64 hex digits** (`DaySlotPolicy.swift:103-107`). `prefix(digits)` stops growing, so `while existing.contains(slug)` loops forever inside a write transaction. It needs 14 or more slots for one key in one day (theoretical). Bound the loop, or fall back to hashing `key + counter`.
- **M6. Weak or phantom assertions:**
  - The fuzz invariant (d) in `DaySlotPolicyTests.assertInvariants` compares two counts that are both filtered by `existing`, so it cannot fail.
  - `assetSlots.count == members.count` holds by construction.
  - `SplitDayPerformanceTests:48` asserts `moves == 334 || moves > 300`.
  - The tests named "…UnderTwoSeconds" assert 10 s.
- **M7. E2 gaps:** `aOneProvinceDayNeverMovesAFileOrWritesAPlaceRow` has no uncached non-representative cell and does not compare `remote_folder` rows before and after (both are in the plan). E19 uses 4 failures, which stays `pending`; the `failed` case (I2) is not covered.
- **M8. Behaviour change from `a16ecf0` for one-province days.** With at most one province known, a result of `unnamed` plus any unanswered cell now waits. That includes days whose representative cells are all sea cells, not only boxes over 300 km. It is transient and converges because the scheduler geocodes every camera cell. Note it in the ADR, because "transient states included, unchanged" is no longer literally true.

## Checked, no issue found

- **DaySlotPolicy convergence.** Probe `zzStability`: 5,000 seeded runs. The plan was applied with pending renames kept, then with renames done, then run twice more. Results: `movedAfterSettle=0 renamedAfterSettle=0 deferredAfterSettle=0 dupFinalNames=0`. No flapping or swap loops, and deferrals resolve once the renames have run.
- **Deferred groups:**
  - their members are skipped;
  - only the slot owner writes `updated`;
  - the day is re-marked in the same transaction;
  - `progress` counts only `changed`, so a deferral cannot spin the cycle.
- **Moves:**
  - `MoveWorker.moveFile` recomputes the target and takes `from` from the job, so a stale move is discarded;
  - a duplicate open move to an older target is harmless;
  - `uploading` jobs are left to `UploadCompletion.commit`;
  - a replace-in-place keeps `remoteLogicalParent`;
  - the crash points sit after the destination call and before the commit; the tests cover 3 targets × 2 points plus a backlog under the cap;
  - file names are allocated per (category, day), so moves between slots of one day never collide.
- **Sidecars** resolve through `LayoutResolver.chain(asset:)`, so they follow the slot. **Views:** shortcuts are Drive-only and keyed by file id, and moves keep ids.
- **LayoutResolver call sites:** all 8 pass the asset, and nothing else builds backup chains through `folderChain(for:placeName:)`.
- **Single-province days with no named → unnamed transition:** no rows, no slots, no moves; the one-group plan always lands on the main slot. Only a key-only `setPlace` write differs from 0.4.0.
- **Geocoding gaps:**
  - no-result answers are cached as empty (`CLGeocoderReverseGeocoder.swift:20`);
  - the scheduler and the policy filter hidden and deleted assets the same way, so "wait for every cell" converges;
  - leaving country-only deletes the rewritten answers, so the cells are asked again rather than read as a new province.
- **Time zones:** the 6-hour check uses the archive time zone; nearest-in-time uses absolute dates within one placement day; placement never changes day; `releaseUnconfirmedPlacements` clears the slot.

## Recommended actions
1. C1: the one-line fix plus a named → unnamed engine test that includes a later NAS.
2. I1: the one-line fix plus a test for an unnamed extra group, including a country-only transition with zero moves.
3. I2: reserve `remote_folder.display_name` drift, plus a failed-rename test.
4. M1–M3: query fixes, best done before the upgrade backlog meets large libraries.

## Unresolved questions
- I2 fix scope: reserve every destination's current display name (my recommendation), or treat a `failed` rename as still pending until the owner retries it?
- Note: the worktree has an uncommitted change to `Tests/PhotoVaultEngineTests/SplitDayRecoveryTests.swift` that is not from this review (probably the recovery reviewer or a developer).

Counts: Critical 1 / Important 2 / Minor 8

Status: DONE_WITH_CONCERNS
Summary: The split engine converges and its moves are crash-safe, but a one-line `??` bug stops named days from ever becoming unnamed (a regression for one-province days, and destinations disagree on the name), and a second one-line bug leaves unnamed extra folders without a row, which defeats the country-only freeze.
