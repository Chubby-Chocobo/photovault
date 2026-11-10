# Plan audit: split a day by place (issue #27)

Scope: `plan.md` and phases 01–08, checked against the code on `feat/27-split-day-by-place` (base 0.4.0) and the owner's choices in the last comment on #27. I read the code only; no tests were run.

## What checks out

- **Slot path shape.** `camera/<day>@<slot>` works with `FolderRefResolver.ref`, which splits on `/` and skips the `camera` prefix that has no row (`FolderRefResolver.swift:13-26`). `FolderEnsurer.invalidate` only matches `path + "/"` (`FolderEnsurer.swift:92`), so it never touches siblings. The `LegacyLayout` GLOBs (`LegacyLayout.swift:12-13`) do not match it. `ArchiveDay(string:)` rejects `08@p…` (`ArchiveDay.swift:21-23`). The 124-byte `pvLogical` limit is not a problem (31 bytes).
- **Moves cannot collide on file names.** Stems are allocated per (category, day), not per folder (`RecoveryWriter.swift:191-198`, `name_alloc`), so moving files between the folders of one day never hits a name clash.
- **Stale moves discard themselves.** MoveWorker recomputes the target at run time (`MoveWorker.swift:122-132`). Replace-in-place uploads commit with the old parent, and `UploadCompletion` then queues the move (`UploadAttempt.swift:154-163`). Sidecar content does not depend on the folder.
- **The cap does not stall.** Rounds 3–9 repeat while there is progress (`SyncCoordinator+Cycle.swift:149-190`, `maxCycleIterations = 100_000`). Moves planned by the namer in one round run in the next, and uploads still go first in every round.
- **Citations hold.** The 7 `LayoutResolver.chain` call sites are correct, including the internal call at `LayoutResolver.swift:31`. `DynamicLayout` is the only `LayoutPolicy` conformer. `feat/24-by-lens-view` adds no migration (verified with `git show`). The crash-point filters exist at `CrashRecoveryTests.swift:52` and `LocalRecoveryTests.swift:132`. `GeocodeScheduler.missing` geocodes every camera cell, promoted days first.

## Critical

### C1. Local recovery with folder rows already in the database puts the main folder on the wrong directory, so one group's files end up in another group's folder

- **Where:** phase 07 (local disambiguation plus the `DaySlotBinding` guard "that path has no `remote_folder` row for this destination").
- **When it happens:** recovery runs while `remote_folder` rows for this destination already exist. That happens when:
  - the owner presses the recovery button in the Advanced tab or "Thử khôi phục lại" (`AdvancedTab.swift:77`, `DecisionCard.swift:159`, `startRecovery(onlyIfRequired: false)`);
  - the database was restored from an older backup.

  `resetState` and `remove` clear the rows (`DestinationRepository.swift:89-97`). An owner-requested recovery does not.
- **Scenario:** at the NAS, Ninh Bình was the largest group, so its folder `2026-11-08 Ninh Bình` is the main folder (`camera/<day>`). Hà Nội is the extra folder `@p1`. The database still holds both rows.
  1. The local loader sorts by collision key, so the Hà Nội folder becomes `camera/<day>` and the Ninh Bình folder becomes `@r…`.
  2. Binding is refused, because both target paths already have rows.
  3. `writeFolders` upserts (`RecoveryWriter.swift:51-54`): `camera/<day>` now points at the Hà Nội directory, a new `@r…` row points at the Ninh Bình directory, and `@p1` still points at the Hà Nội directory. Two logical paths now share one directory.
  4. `write` (`:170-172`) queues the Ninh Bình files from `@r…` to the main folder, which is now the Hà Nội directory. **The Ninh Bình photos are moved into the Hà Nội folder.**
  5. A later rename of the main folder moves the shared directory. `rebasePaths` only rewrites descendants (`OrganizationQueries.swift:30-38`), so the `@p1` row keeps a path that no longer exists. `landedParent` and `StartupRecovery` then pick "the first row with this remote id" (`UploadAttempt.swift:177`, `StartupRecovery.swift:117`).
  6. `day_place` gains `r…` "Ninh Bình" while `day_stat` is still named "Ninh Bình", which breaks the slot invariant.

  This violates success criterion 4. With a restored pre-split database the same path moves the files twice.
- **Recommended change (phase 07):**
  1. **Bind local folders by path first.** A listed directory whose path equals an existing row's `remote_id` takes that row's logical path.
  2. Then bind to known slots by display name.
  3. Only folders still unbound fall back to "first by collision key = main, others `r…`".
  4. In `writeFolders`, refuse (and log) any write that would leave two logical paths with the same `remote_id` at one destination.
  5. Add tests:
     - **R5:** owner-requested recovery on the real local destination with the database intact, where the main folder is *not* first by collision key. Expect zero moves and an unchanged listing.
     - **R6:** a database restored from before the split, then recovery.

## Important

### I1. Country-only fallback and "Làm mới địa danh" make split days collapse and split again: mass Drive moves, twice

- **Scenario:**
  - `enterCountryOnly` rewrites `administrative_area = country` and marks every promoted day dirty (`GeocodeScheduler.swift:168-176`). Every split day then has one identity (VN), is delegated and gets one group, so the files of every extra folder move back to the main folder.
  - The first province answer after that runs `noteProvinceSeen`, which deletes the rewritten answers and marks every day dirty again (`:140-150`). After geocoding, every day splits again and the files move out a second time.
  - `refreshAll` resets `provinceSeen` (`:220-222`). So an owner refresh whose first 10 answers are water cells is enough to trigger the cycle.
  - Today this costs one rename per day. With splits it costs one Drive write per file, twice.
- **Change:** while `place_country_only = 1`, do not change slots. Keep the day's current slots and update names only, as today; in other words, `DaySplitWriter` skips step 4 and slot assignment. Alternatively, treat country-level identities as "unknown" for splitting. Add a test: split day, then country-only mode, then province seen again. Expect zero `moveFile`.

### I2. Recovery order NAS → Drive is not covered, and binding is unspecified for Drive

- `runPending` walks destinations in database order, not by kind (`RecoveryService.swift:52-66`).
- If the NAS is recovered first after a database loss, the slots come from the local collision-key order: main = Hà Nội, `r…` = Ninh Bình, while the truth is the opposite. Drive is recovered next, and its `pvLogical` paths disagree with those slots.
  - If binding is not applied to Drive, every file of every split day is queued to move on Drive.
  - If it is applied, the Drive rows no longer match the folders' `pvLogical`. That is acceptable, but it must be documented.
- **Change:**
  - Say explicitly that `DaySlotBinding` runs for every destination kind, and that `pvLogical` decides only when no known slot matches by name. Or recover destinations that support app properties first.
  - Add R3b: NAS then Drive, zero moves at both.

### I3. `DaySlotPolicy` is ambiguous about pass order, the "drop old name" step can reuse a folder name that is still on disk, and the slug rule can merge different names

- **Pass order.** The plan does not say whether pass 1 runs over all groups before pass 2, or all passes run per group. The two readings give different results (see M1).
- **Dropped names.** After a key or main match, the slot's old name is dropped from the index, so a later group in the same run can open a *new* slot with that old name. The rename of the old slot may not have run yet at some destination (renames retry, `MoveWorker.swift:73`). Local `ensureFolder` then adopts the still-existing directory (`LocalFileOps.swift:103-110`). When the rename runs, it carries the new slot's files away, and their stored paths become stale. The stated invariant ("slots before and `updated` after") actually forbids this, so the plan contradicts itself.
- **Slug lengthening.** Pass 4 lengthens a slug only "if it exists for another key". If key pass 2 skipped the row for key K because another group took it, pass 4 computes the same `p` slug for K and lands in that already-assigned slot. Two groups with different names then share one folder.
- **Change:**
  - Specify that each pass runs over all groups before the next.
  - Keep names that are vacated during a run reserved until the end of the run: a group with that name matches the vacating slot.
  - Lengthen the slug whenever it already exists or was assigned in this run.
  - Extend the fuzz invariant: (a) no two distinct slots across before ∪ after share a collision key; (b) every group's name collision key equals its slot's final collision key.

### I4. Recovery's slot adoption is underspecified

- After phase 04, `chain` reads `asset.placeSlot` from the in-memory record. `write` must set `placed.placeSlot` together with `setPlaceSlot`, otherwise the first file of every asset in an extra folder queues a move to the main folder (`RecoveryWriter.swift:127-131,170-172`). R1 would catch this, but the phase text should say it.
- An asset whose files were split across two folders when the database was lost (a split move half done) takes the slot of whichever file sorts first by `remoteId` (`RemoteInventory.swift:140,215`). That is often a sidecar. **Change:** take the slot from the primary resource's folder, or from the majority of the asset's files.

### I5. Test matrix gaps

Beyond R5, R6, R3b and I1, add:

- a destination added after a day was split: both folders are created with their final names and no move is made;
- destination rules that exclude the whole main group at one destination: only the `@slot` folder exists there, followed by recovery of that destination;
- `LegacyLayout.isPresent` on a database that holds `camera/<day>@p…`: phase 03 tests only `LegacyRootProbe`;
- a crash in the middle of the upgrade backlog, combined with the cap;
- place names turned off after a split: nothing moves;
- success criterion 3 extended to "no pending **or failed** `move_job`". Failed moves are never planned again, so a sidecar can stay apart from its original silently.

## Minor

- **M1. Unnamed main folder.** On the 0.3.0 upgrade, the main folder of a multi-province day is unnamed: its name collision key is the bare date and its key is nil. Pass 1 (bare date = bare date) or pass 2 (nil == nil) gives the main folder to any *unnamed* group, so the largest group moves instead. Fix: never match on nil keys, and leave a never-named main folder to pass 3.
- **M2. Upgrade state flips.** Step 4 (wait until every cell has `en`) runs before delegation. The upgrade backfill therefore flips one-province named days with a missing non-representative cell to `waitingGeocode`. `LayoutResolver` then gives a bare name for folders created meanwhile (`LayoutResolver.swift:20`). This contradicts the "byte-identical" claim. Fix: if the known identities are ≤ 1, return the delegated result. The missing cell's answer marks the day dirty anyway (`DirtyQueue.swift:34-38`).
- **M3. Budget section incomplete.** It covers only the upgrade and the steady state. A fresh install, or a large Drive/Dropbox import (#17), uploads every multi-province day into the main folder first and then moves the other groups. Document this cost.
- **M4. Rollback text is wrong.**
  - Reverting phase 07 without 04 makes recovery adopt NULL slots, which queues every file in an extra folder back to the main folder.
  - A downgraded build commits sidecar replacements against the main folder, which separates sidecars from their originals.
  - Fix: say that 01 and 04 must stay, and that a v6 database must refuse to run on an older build.
- **M5. `enqueueRename` still scans `open()`.** It loads every open move per call (`OrganizationQueries.swift:81`), which is quadratic with the upgrade backlog. Use the new index there too.
- **M6. Timezone restore.** `restoreTimezone` deletes `day_stat` (`RecoveryService.swift:163`). It should also clear `day_place` and `asset.place_slot`.
- **M7. Late-arrival guess (phase 06).** It ignores GPS, so a GPS photo from another province costs one upload plus one move. It is also a second writer of slots, against the plan's "slots change only in `PlaceNamer`". Either map a cached `en` identity to a slot by key, or cut the guess (YAGNI) and accept one move per late file.
- **M8. Deleted assets stay in the old folder** after the first split. Deleted Ninh Bình photos stay in the main folder, now renamed "Hà Nội". Say this in ADR 0028 and the README.
- **M9. Hidden toggle.** Turning "hidden upload" on or off does not re-evaluate places: the sweep covers only view, sidecar and description (`OrganizationStages.swift:47-49`). The issue exists today, but grouping now depends on it.
- **M10. Vietnam's 2025 province merger.** Cached answers from before an Apple data update and newer answers can disagree, which can create spurious splits (an old province name next to the new merged one). Note FR-106 refresh as the remedy.
- **M11. Waiting main folder.** While the main folder is `waitingGeocode`, its display name is the bare date. That can collide with an unnamed extra folder when a folder is created. Use the stored name for the main folder's display whenever it is non-nil and the state is `waitingGeocode`.
- **M12. Dead rule.** "No `creationDate` → largest group" never applies, because undated assets are placed on `unknown` and never appear in `cameraAssetKeys`. Drop it.

## Unresolved questions

1. Should an owner-requested recovery be allowed to rewrite existing `remote_folder` rows at all, or only add missing ones? C1's fix assumes path identity wins.
2. Should country-only mode freeze splits (I1), or is collapsing to one country folder per day what the owner wants in that mode?

Counts: Critical 1 / Important 5 / Minor 12

Status: DONE_WITH_CONCERNS
Summary: The slot design holds up against `FolderRefResolver`, `FolderEnsurer`, `MoveWorker`, `LegacyLayout` and the cap. Local recovery with existing folder rows (C1) can put one group's files into another group's folder. Country-only transitions (I1) cause mass moves.
