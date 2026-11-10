---
phase: "07"
title: "Engine: recovery of split days"
status: pending
priority: P1
size: L
human_effort: 3-5h
dependencies: ["05"]
touches:
  - Sources/PhotoVaultEngine/RemoteInventory.swift
  - Sources/PhotoVaultEngine/DaySlotBinding.swift
  - Sources/PhotoVaultEngine/RecoveryService.swift
  - Sources/PhotoVaultEngine/RecoveryWriter.swift
  - Sources/PhotoVaultEngine/HardeningTypes.swift
  - Tests/PhotoVaultEngineTests/DayFolderRecoveryParsingTests.swift
  - Tests/PhotoVaultEngineTests/DaySlotBindingTests.swift
  - Tests/PhotoVaultEngineTests/SplitDayRecoveryTests.swift
acceptance:
  - swift test --filter DayFolderRecoveryParsingTests
  - swift test --filter DaySlotBindingTests
  - swift test --filter SplitDayRecoveryTests
  - swift test --filter LocalRecoveryTests
  - swift test --filter RecoveryTests
---

# Phase 07: recovery

## Overview

Size L: recovery is the trust boundary for a database loss. Split days must come back with zero moves and zero renames whether recovery is owner-requested with an intact database, follows a restored older backup, or follows a database loss, from Drive, from a local tree, or both in either order.

## Requirements

### Inventory (`RemoteInventory.swift`)

- `RemoteFolderEntry` gains `slot: String?`. `RemoteFileEntry` gains `parentFolderId: String?`, set by both loaders: the Drive parent id, or the local directory path.
- Drive: `dayFolder` (`:150`) uses `DynamicLayout.parseCameraDay` and returns the day, slot and place.
- Local: the loader marks camera day folders but does **not** choose main or `r…` any more. `DaySlotBinding` does that.

### DaySlotBinding (new, pure)

`bind(_ inventory:, known: [ArchiveDay: [DaySlot]], rows: [RemoteFolder] /* this destination */, isDrive:) -> (RemoteInventory, conflicts: [String])`.

For each listed camera day folder, in collision-key order, stop at the first rule that applies:
1. **Remote id:** a row with `remote_id ==` the folder's id takes that row's logical path.
2. **Display name:** a known slot of that day with the same display collision key takes its path, unless a row for that path points at a *different, still listed* folder.
3. **Fallback:**
   - Drive: the folder's `pvLogical`.
   - Local: `camera/<day>` for the first remaining folder of the day.
   - Otherwise, and also when the fallback path is already bound in this run or held by a row whose remote id is still listed: `@` + `DaySlotPolicy.slug(forRecoveredName:)`, lengthened if taken.

Then:
- Rewrite every file's `parentLogical` through `parentFolderId`.
- A logical path bound to two listed folders becomes a conflict: the second folder is skipped, and its files keep `parentLogical = nil`, so they are not adopted.
- `RecoveryService.run` (`RecoveryService.swift:120`) calls `bind` after the legacy check for **every destination kind** (audit I2), with:
  - known slots: main from `day_stat`, rows from `day_place`, including `reservedNames`;
  - this destination's rows.

### RecoveryWriter

- `writeFolders` (`:44`): **never re-point a row whose `remote_id` is still listed.**
  - An existing row whose remote id equals the folder's may get `created = true` and the listed display name.
  - A missing row is inserted.
  - A row whose remote id is gone from the listing (stale) may be re-pointed.
  - A write that would give two logical paths one remote id is refused, logged (`category: recovery`, no names) and counted in `RecoveryStats.folderConflicts` (`HardeningTypes.swift:21`). It is reported with one activity row (bilingual `tr`, no folder names) together with the binder's conflicts.
  - Slot folders: `INSERT OR IGNORE INTO day_place(day, slot, NULL, placeName)` and promote the day. `adoptDay` stays for main folders only.
- `writeFiles` (`:83`), before chunking:
  - Snapshot `preSplitDays` = the days for which `DayPlaceRepository.days` had no row when this recovery started. Take it before `writeFolders`.
  - Compute `slotByAsset`: the slot of the folder of the asset's primary resource (`ResourcePlanner.primary` over the asset's resources) among this destination's matched files. Without one, the slot of the folder holding most of its files, a tie going to the main folder (audit I4).
- `write` (`:115`): adopt `slotByAsset[asset]` when the placement was adopted in this run, or when `asset.placeSlot == nil` and the placement day is in `preSplitDays`, and only if the folder's day equals the placement day.
  - Set **both** `setPlaceSlot` and `placed.placeSlot` before the target is computed (`:170`).
  - Otherwise keep the database's slot; an existing move is enqueued when it differs (`:171`).
- `releaseUnconfirmedPlacements` (`:22`) also sets `place_slot = NULL`.
- `RecoveryService.restoreTimezone` (`RecoveryService.swift:163`, audit M6): after `DELETE FROM day_stat`, also run `DayPlaceRepository.deleteAll` and `clearPlaceSlots`. It runs only when no job has a file.

## Tests first

`DayFolderRecoveryParsingTests` (extend): a Drive `@p…` folder gives day, slot and place; `@bad` is not a day folder.

`DaySlotBindingTests`:
1. A local intact database: rows bind by path even when the main folder is not first by name (the C1 case). No `r…`.
2. A database knows main "Hà Nội" and `p1` "Ninh Bình", no rows at this destination: both bind by name.
3. A stale main row (its path is gone): the folder named like the known main binds to it.
4. Unknown names on a fresh database, local: first → main, others `r…`; the slugs are stable over two calls.
5. Drive `pvLogical` already bound in this run: `r…`.
6. Two folders that resolve to one path: one conflict reported.
7. Determinism.

`SplitDayRecoveryTests`. Setup: E1 at Drive and NAS, with NB the *largest* group at the NAS side where needed, so that main is not first by name. Afterwards always expect: an unchanged listing, zero `move_job`s and renames after recovery and after the geocoder is re-seeded and settled, unique remote ids among the rows, and the same `day_place` names.

| # | Case |
|---|---|
| R1 | Drive fake, database lost |
| R2 | real local (`useRealLocal`), database lost |
| R3 | Drive then NAS fake, database lost |
| R3b | NAS then Drive (audit I2) |
| R4 | one-province day, local; existing `t31LostDatabaseIsRecoveredFromTheFolderTree` stays green |
| R5 | owner-requested recovery (`startRecovery(onlyIfRequired: false)`) with the database intact, real local and Drive; the NAS main folder is "Ninh Bình", so not first by name (audit C1) |
| R6 | database restored from a backup taken before the split, with the day's main folder renamed since; recover NAS then Drive, and Drive then NAS |
| R7 | NAS rules exclude the HN group (E15 state): intact database (owner-requested) and lost database, NAS first, then Drive |
| R8 | a forced conflict (two listed local folders whose paths both bind to `camera/<day>` through a corrupted row set): one activity row; `folderConflicts == 1`; nothing moved |
| R9 | timezone restore on a fresh database clears `day_place` and slots |

## Risks

- **A split folder renamed by hand:** the name no longer matches, so after geocoding a new folder is created and files move. This is today's rename-after-recovery behaviour.
- **Stale-row re-pointing** was confirmed by the lead (plan, Decisions). R6 depends on it.
- **Unknown:** `RecoveryMatcher` might use `parentLogical` somewhere. Re-grep it before changing it; fingerprints come from names.

## Rollback

Revert with 05 and 06 and keep 01 to 04. Recovery then reads `@` folders as plain folders: they get rows and their jobs point at them, so nothing is re-uploaded.
