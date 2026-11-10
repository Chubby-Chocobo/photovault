---
title: "Split one camera day into one folder per province"
description: "A camera day with photos from several provinces/cities gets one Camera Uploads folder per province; files and sidecars already uploaded are moved with MoveWorker."
status: pending
priority: P2
size: L
human_effort: 11.5-21h
branch: feat/27-split-day-by-place
issue: 27
tags: [feature, backend, database]
created: 2026-11-10
sources:
  - "tracker: github:Chubby-Chocobo/photovault#27"
  - "spec: file:docs/requirements/photovault-spec-v1.md"
authoritative: "tracker: github:Chubby-Chocobo/photovault#27"
---

# Plan: split a day by place (issue #27)

The owner's choices, from the last comment on the issue (auto mode): split by province (key `isoCountryCode|administrativeArea` in `en`). Photos without GPS join the group of the GPS photo nearest in time. There is no minimum group size. A → B → A puts all A photos in one folder. Folders sort by name, with no ordinal. Files already backed up are moved. Splitting waits until the day ended ≥ 6 h ago (FR-83). Screenshots and Saved are never split, and the views are unchanged.

The audit (`reports/plan-audit-split-day.md`) and the lead's decisions of 2026-11-10 are folded in. The changelog is at the end.

## Outcome

```
Camera Uploads/
├── 2026-11-08 Hà Nội/          logical camera/2026-11-08               (main folder, as today)
├── 2026-11-08 Ninh Bình/       logical camera/2026-11-08@p3f9a1c2e4b5d (extra folder of a split day)
└── 2026-11-09 Đà Lạt/          one-province day: byte-identical to today, no moves, no new rows
```

## Data flow

1. **In:** a Photos change or an import goes through `AssetFinalizer.finalize`/`recount` (`Sources/PhotoVaultEngine/AssetFinalizer.swift:29,48`). The asset is placed and the day is marked dirty on `.place`.
   - On a day that is already split, a new asset, which has no file yet, gets an initial slot. If its cell has a cached `en` answer whose key matches a slot of the day, it takes that slot; otherwise it takes the slot of the live asset nearest in time (phase 06).
2. **Evaluate:** at least 6 h after the day ended, `PlaceNamer.evaluate` (`PlaceNamer.swift:49`) reads the day's camera assets and `geo_cache`.
   - In country-only geocode mode (`kv.place_country_only = 1`), a day already split is left exactly as it is. An unsplit day is named by today's rule only.
   - Otherwise `PlaceSplitPolicy` (pure) returns `pending`, `waitingGeocode`, or groups of the shape `{key, name, members}`.
   - `DaySlotPolicy` (pure) then maps the groups onto slots: `nil` is the main folder (`day_stat`), a string is an extra folder (`day_place` row).
3. **Persist:** in the same transaction, `DaySplitWriter` writes `day_stat`, `day_place` and `asset.place_slot`, plus `move_job`s (`renameFolder` for changed names, `moveFile` for every job with a remote file whose asset changed slot).
4. **Execute:** the next round's `MoveWorker` (`MoveWorker.swift:118`) resolves the target with the slot-aware `LayoutResolver.chain` and runs `FolderEnsurer.ensure`, which creates `camera/<day>@<slot>` with `pvLogical`. It then calls `destination.move` and `MoveCommit.file`. Sidecars are `upload_job`s with the same placement, so they move the same way.
5. **Out:** the folders at Drive and the NAS, and one coalesced activity row per destination per hour (`MovePassActivity`).
6. **Recovery** (any destination kind, any order):
   1. `RemoteInventoryLoader` lists the destination.
   2. `DaySlotBinding` binds each listed day folder: to an existing `remote_folder` row by remote id, then to a known slot by display name, then by fallback (Drive `pvLogical`; local name order, the main folder first and the others `r…`).
   3. `RecoveryWriter` adds only missing rows. It re-points only rows whose remote id is no longer listed, and refuses and reports two logical paths pointing at one remote id.
   4. It sets an asset's slot from the folder of the asset's primary file, when the database has no say.
   5. The first `PlaceNamer` run after geocoding matches folders by name, so it moves nothing.

## Phases

| Phase | Name | Status | Size | Depends |
|---|---|---|---|---|
| 01 | [Store: slot column, day_place table, move index, newer-schema guard](phase-01-store-slot-and-day-place.md) | Pending | L | — |
| 02 | [Core: PlaceSplitPolicy (grouping)](phase-02-core-place-split-policy.md) | Pending | M | — |
| 03 | [Core: DaySlotPolicy and slot-aware layout](phase-03-core-day-slot-policy-and-layout.md) | Pending | M | 02 |
| 04 | [Engine: slot-aware LayoutResolver plumbing](phase-04-engine-layout-plumbing.md) | Pending | M | 01, 03 |
| 05 | [Engine: split evaluation and move planning](phase-05-engine-split-evaluation.md) | Pending | L | 04 |
| 06 | [Engine: move crash points, pass cap, late arrivals](phase-06-engine-moves-and-late-arrivals.md) | Pending | M | 05 |
| 07 | [Engine: recovery of split days](phase-07-engine-recovery.md) | Pending | L | 05 |
| 08 | [App text and docs](phase-08-app-text-and-docs.md) | Pending | S | 06, 07 |

Dependency graph: `01 ∥ 02 → 03 → 04 (needs 01) → 05 → {06 ∥ 07} → 08`. File ownership: phases 01 and 02 touch disjoint files, and so do phases 06 and 07. The `touches` lists in the phase files are authoritative.

## Decisions

### Data model for groups
- Chosen: a nullable `asset.place_slot` column (NULL means the main folder `camera/<day>`), plus a table `day_place(day, slot, place_key, place_name)` for the extra folders. The main folder keeps using `day_stat.place_key/place_name`.
- Alternatives: compute the group on the fly in `LayoutResolver` from geocodes; add a group field to `Placement`; one `day_place` table that also holds the main folder.
- Why: a one-province day writes no new rows and the layout reads what it reads today. Slot changes that imply moves happen only in `PlaceNamer`; recovery and the placement guess set slots only where nothing has to move. `Placement` is "fixed once" (spec §8.1). Computing on the fly would move files whenever a geocode answer changed, outside the 6 h rule.
- Review later: no

### Logical path shape
- Chosen: the main folder stays `camera/<day>`. An extra folder is a sibling, `camera/<day>@<slot>`, with the display name `YYYY-MM-DD <name>`. Slugs: `p` plus 12 or more hex digits of SHA-256 of the province key, or `r` plus 12 or more hex digits of SHA-256 of a recovered folder name's collision key.
- Alternatives: nested `camera/<day>/<key>`; give every group a new path; put the key in clear text.
- Why: `FolderRefResolver.ref` (`FolderRefResolver.swift:13`) and `FolderEnsurer.invalidate` (`FolderEnsurer.swift:88`) treat `/` as nesting. Giving every group a new path empties the old day folder, which is never deleted (§8.7.4). A key-derived slug survives renames. `@` matches neither `LegacyLayout` (`LegacyLayout.swift:13`) nor `LegacyRootProbe` (`LegacyRootProbe.swift:31`), and the value is 31 bytes, under the 124-byte `pvLogical` limit.
- Review later: no

### Slot matching (DaySlotPolicy)
- Chosen: four passes. Each pass runs over all groups, in order (members descending, then key), before the next pass starts.
  - The name index holds every existing slot's current name, plus the old names of its open renames. It also holds every name assigned during the run, and it never forgets a name within a run.
  - Every pass first looks the group's display-name collision key up in the index.
  - Pass 1 is that lookup alone. Pass 2 matches by key, non-nil keys only. Pass 3 gives the main folder, if still free, to the first unassigned group. Pass 4 creates a new `p…` slot, lengthening the slug whenever it already exists or was assigned in the run.
  - A main folder that was never named takes part in pass 1 only when some group is unnamed. Otherwise it is left to pass 3, so the largest group stays in place (audit M1).
- Alternatives: match by key only; run all passes per group; drop vacated names from the index.
- Why: matching by name first keeps every folder name of a day unique, including names still on disk while a rename retries. Local `ensureFolder` adopts an existing directory of the same name (`LocalFileOps.swift:97`), so a reused name would make two logical folders share one directory. Matching by key keeps renames as one operation. The fuzz test asserts two things: (a) no two distinct slots over before ∪ after share a collision key, counting reserved names; (b) every group's collision key equals its slot's final collision key.
- Review later: no

### Grouping needs every cell's English geocode only when there are two or more provinces
- Chosen: if the cells that already have an `en` answer show at most one province, delegate unchanged to `PlaceNamingPolicy.evaluate`, which behaves as today, transient states included. Once two or more provinces are known, wait for every cell's `en` answer, then evaluate each group alone with `PlaceNamingPolicy`.
- Alternatives: always wait for every cell (the first version of this plan); decide on the 30 representative cells only.
- Why: this is byte-identical for one-province days (audit M2). It still honours "no minimum", because a later answer for a detour cell marks the day dirty (`DirtyQueue.swift:34-38`) and splits it then. `GeocodeScheduler` already geocodes every camera cell, promoted days first (`GeocodeScheduler.swift:187`).
- Review later: no

### Assets without a usable place
- Chosen: an asset with no GPS, a cell without a province (sea), or a hidden photo while hidden upload is off joins the identity-carrying photo nearest in creation time; a tie goes to the earlier photo, then the smaller id. Deleted assets keep their slot and never move. Changing the hidden-upload setting re-evaluates every promoted day once (`kv.place_hidden_basis`).
- Alternatives: give them their own `YYYY-MM-DD` folder; let deleted assets follow their group; re-evaluate places on every settings change.
- Why: owner decision 2, and T23 (a deleted photo's backup stays where it is). Grouping now depends on the hidden filter, and the settings sweep does not cover `.place` (`OrganizationStages.swift:47-49`, audit M9).
- Review later: no

### Two groups with the same display name
- Chosen: they share one folder, which falls out of the name index. The slot takes the key of its largest group.
- Alternatives: a ` (2)` suffix; fall back to the province name.
- Why: the owner sees one name, so one folder is what they would expect. A suffix would look like the ordinal the owner rejected. It needs two unnamed groups (a group box over 300 km) or the same locality name in two provinces.
- Review later: yes

### Emptied extra folders
- Chosen: never delete a `day_place` row or a folder. Later groups with the same name reuse the folder.
- Alternatives: trash an empty extra folder after a listing proves it is empty.
- Why: §8.7.4, and `Destination` has no delete. Collapses need location edits or a refresh; country-only mode freezes, and deletions freeze.
- Review later: yes

### Country-only geocode mode freezes splits (lead decision)
- Chosen: while `kv.place_country_only = 1`, `PlaceNamer` leaves every day that has `day_place` rows untouched: no slot change, no rename, no new split. A day without rows is evaluated by today's `PlaceNamingPolicy` alone, so two countries give an unnamed day as today. When provinces return (`noteProvinceSeen` marks every day dirty), evaluation resumes.
- Alternatives: collapse to one country folder per day; treat country-level identities as unknown.
- Why: entering and leaving the fallback (`GeocodeScheduler.swift:140-176`), including through an owner refresh whose first 10 answers are water cells, would otherwise move every file of every split day twice (audit I1).
- Review later: no

### When groups are computed
- Chosen:
  - Only in `PlaceNamer` (step 9), with today's triggers: promotion, a change to the day's asset set (new, deleted, location edit, import), a geocode answer for one of the day's cells, and the time-based `pending` poll.
  - Plus a one-time upgrade pass (`kv.place_split_backfill`) and the hidden-basis change.
  - While place names are off, nothing is split or merged.
- Alternatives: split at placement; a separate split stage.
- Why: FR-83 (≥ 6 h), and it reuses the dirty queue. The upgrade pass implements owner decision 6, because today's multi-province days are `unnamed` and would not be evaluated again.
- Review later: no

### Late arrivals in an already split day
- Chosen: when an asset is placed on a day that has `day_place` rows, it takes the slot whose key matches its cell's cached `en` identity. Without one, it takes the slot of the live camera asset nearest in time. `PlaceNamer` corrects the guess later.
- Alternatives: no guess, which costs one upload plus one move per late file; nearest in time only (the first version of this plan).
- Why: imports of old trips (#17) land on split days, and the key mapping handles GPS photos from another province (audit M7). The asset has no file yet, so setting its slot moves nothing.
- Review later: no

### Moves: reuse MoveWorker, cap per pass
- Chosen:
  - One `moveFile` per job with a remote file, at every destination, sidecars included. Uploading jobs are left to `UploadCompletion.commit`.
  - `enqueueMove` and `enqueueRename` use the new `move_job(destination_id, subject)` index instead of scanning `open()` (`OrganizationQueries.swift:58,81`).
  - At most `EngineTuning.maxMovesPerPass = 500` per destination per pass.
  - Success requires no pending **and no failed** move jobs.
- Alternatives: a dedicated split mover; moving whole folders.
- Why: MoveWorker is already crash-safe and recomputes the target at run time. The cycle repeats rounds while there is progress (`SyncCoordinator+Cycle.swift:149-190`), so the cap does not stall; it only keeps one round short.
- Review later: yes

### Recovery binding (lead decision, audit C1 and I2)
- Chosen: `DaySlotBinding` runs for every destination kind, in any recovery order. For each listed camera day folder:
  1. **By remote id:** an existing `remote_folder` row of this destination whose `remote_id` equals the listed id (the Drive id, or the local path) gives its logical path.
  2. **By display name:** a known slot of the day (main from `day_stat`, extra from `day_place`) with the same collision key gives its logical path, unless that path already has a row pointing at another listed folder.
  3. **Fallback:** on Drive, the folder's own `pvLogical`; on a local destination, the first unbound folder by collision key becomes `camera/<day>` if that path is free, and the others become `@r…`. On Drive, a `pvLogical` already taken falls back to `@r…`.
  - `RecoveryWriter.writeFolders` never re-points a row whose remote id is still listed. It adds missing rows, and may re-point only a row whose remote id is gone from the listing (a stale row from a restored backup). It refuses, logs and reports (activity row, `RecoveryStats.folderConflicts`) any write that would give two logical paths one remote id.
- Alternatives: always trust `pvLogical`; recover Drive first; never touch existing rows, stale ones included.
- Why: path identity is the only thing that cannot be wrong after an owner-requested recovery with an intact database (C1). Binding by name aligns a second destination with slots the first one recovered (I2). After binding, Drive rows can disagree with a folder's `pvLogical`; that is harmless, because only recovery reads `pvLogical`, and it checks rows and names first.
- Review later: yes

### Stale folder rows may be re-pointed (lead decision, 2026-11-10)
- Chosen: during recovery, an existing `remote_folder` row is re-pointed only when its `remote_id` no longer appears in the destination's listing (a stale row). A row that points at a listed folder is never touched.
- Alternatives: add missing rows only and never re-point any row.
- Why: avoids recreating a bare `YYYY-MM-DD` day folder and moving a whole group into it after a restored pre-split backup (R6). Leaving listed rows alone keeps the C1 guarantee.
- Review later: no

### Recovery slot adoption (audit I4)
- Chosen: `RecoveryWriter` sets the slot on the persisted row **and** on the in-memory `placed` record before computing the target. It adopts the slot when (a) it adopted the placement in this run, or (b) the asset's slot is NULL and the day had no `day_place` rows when this recovery started (a restored pre-split database). The slot comes from the folder of the asset's primary resource (`ResourcePlanner.primary`) on this destination, else the folder holding most of the asset's files (a tie goes to the main folder). It is computed over all matched files before chunking.
- Alternatives: first file by `remoteId` (often a sidecar); never adopt for already-placed assets.
- Why: without the in-memory update, the first file of every asset in an extra folder would queue a move to the main folder. A split move half done at the time of the loss must not pull the original toward a sidecar.
- Review later: no

### Downgrade protection
- Chosen: from this release on, `Store.open` refuses a database that holds migrations it does not know (`DatabaseMigrator.hasBeenSuperseded`, available in the pinned GRDB) with `StoreError.newerSchema`. The app then shows its existing "Could not open the database" launch failure (`AppEnvironment.swift:127-129`). The README says not to downgrade.
- Alternatives: none for 0.3.0, which is already shipped and cannot learn the guard.
- Why: a downgraded build ignores `place_slot` and would commit sidecar replacements against the main folder (audit M4). Only future downgrades can be blocked.
- Review later: no

### Waiting main folder keeps its name
- Chosen: `LayoutResolver` gives the main folder its stored `place_name` while the state is `waitingGeocode`, not only when `named`.
- Alternatives: today's behaviour (bare date while waiting).
- Why: today a folder created while waiting gets the bare date and is never renamed back, because `renamed = name != stat.placeName` is false. With splits it could also collide with an unnamed extra folder (audit M11). This intentionally fixes a latent naming bug; it never causes a move.
- Review later: no

### Decision record number
- Chosen: `docs/decisions/0028-split-day-by-place.md`.
- Alternatives: 0027.
- Why: `feat/24-by-lens-view` already adds `0027-by-lens-view.md`. If it has not merged by then, take the next free number.
- Review later: no

## Drive write budget for moves

- One file move is one `files.update` call through `DriveWriteLimiter.standard()`: a burst of 30, then 5 calls/s (`DriveWriteLimiter.swift:8`). Creating a new extra folder costs 1 to 2 calls, and a rename costs 1. An asset has 2 to 6 jobs with files.
- **Upgrade:** `moves ≈ files in non-main groups of multi-province days`. For example, 2,500 assets × 3 files = 7,500 calls ≈ 25 min of bucket time, in passes of at most 500 (≤ 100 s each).
- **Fresh install, or a large Drive/Dropbox/folder import (#17):** files uploaded before their day's cells are geocoded (20 requests/min) land in the main folder, and their non-main groups move later. Cost: 1 call per such file, at most the same order as the upgrade backlog. It shrinks because backfill and geocoding both go newest first, and geocoding favours promoted days. Imports into days that are already split use the placement guess and do not move.
- **Steady state:** the non-main groups of one day, usually tens of files.
- There is no daily-cap impact, because the cap counts bytes. On a NAS a move is a same-volume `renameat`.

## Test matrix

| Level | What | Where |
|---|---|---|
| Unit (Core) | grouping, nearest in time, A→B→A, sea cells, hidden, deleted, delegation while known identities ≤ 1; slot passes over all groups, reserved and vacated names, nil keys, never-named main, slug lengthening, merge; fuzz invariants (a) and (b); slot-aware layout | 02, 03 |
| Unit (Store) | v6 migration on a v5 file, upsert keeps `place_slot`, `DayPlaceRepository`, newer-schema refusal | 01 |
| Engine integration (Harness, `FakeDestination` Drive + NAS) | T28 two provinces become two folders; one-province day byte-identical; upload before 6 h, then split moves sidecars; import into a named day; A→B→A; location edit collapses; deletion freezes; late geocode waits, then splits; upgrade backfill splits once (idempotent); same-name merge; Screenshots/Saved untouched; shortcut ids unchanged; integrity clean; destination added after a split; rules exclude the main group at one destination; place names off; country-only freeze and unfreeze; hidden toggle; `LegacyLayout.isPresent` false; waiting-name display | 04, 05 |
| Crash points | `afterMoveStarted` and `afterMoveBeforeCommit` × Drive fake, NAS fake, real local; folder-create points during a move; crash in the middle of an upgrade backlog under the cap | 06 |
| Recovery parity | R1 Drive, R2 real local, R3 Drive→NAS, R3b NAS→Drive, R4 one province, R5 owner-requested with an intact database (main folder not first by name), R6 restored pre-split database, R7 main group excluded at the NAS (intact and lost database); timezone restore clears slots | 07 |

## Success criteria

1. `swift test` passes, including `PlaceSplitPolicyTests`, `DaySlotPolicyTests`, `SplitDayLayoutResolverTests`, `SplitDayTests`, `SplitDayMoveTests`, `DaySlotBindingTests` and `SplitDayRecoveryTests`.
2. A one-province day yields an empty `day_place`, NULL `place_slot`, the same `remote_folder` rows, and 0 moves.
3. A two-province day yields exactly two `Camera Uploads/<day> …` folders at every destination that receives both groups. Every file and sidecar of each asset sits in its group's folder, and after settling there is no pending **or failed** `move_job`.
4. After every recovery case R1 to R7, the folder listing is unchanged, no `move_job` is queued, and no two `remote_folder` rows of one destination share a remote id.
5. The app builds unsigned. The spec, decision 0028 and the README describe the split.

## Risks

| Risk | L×I | Mitigation |
|---|---|---|
| A one-province day changes (name or moves) | L×H | delegation while known identities ≤ 1; the main slot is chosen first; byte-identical test in 05 |
| Upgrade or import backlog floods Drive writes | M×M | cap of 500, indexed dedupe, shared limiter; budget above |
| Two folders with the same name | M×H | name index with reserved names, fuzz invariants (a) and (b), recovery binding by id first |
| Recovery moves files or re-points live rows | M×H | binding order id → name → fallback; rows still listed are never re-pointed; conflicts refused; R1 to R7 |
| Country-only transitions cause mass moves | M×H | freeze (lead decision); test in 05 |
| Apple's data for Vietnam's 2025 province merger: old and new cached answers disagree, giving spurious splits | M×M | FR-106 "Làm mới địa danh" re-asks every cell. Regrouping after a refresh moves files, which is noted in ADR 0028 and the README |
| Longer `waitingGeocode` for days with known detours | L×L | only once two provinces are known; the folder keeps its name while waiting |
| Merge conflicts with `feat/24-by-lens-view` | M×L | new entities in new files; rebase after #24; ADR 0028 |
| Existing crash suites fail on the new points | H×L | filters updated in 06 |

## Backwards compatibility and rollback

- The migration `v6-day-place` only adds things. An older 0.4.x build after this one refuses a newer schema (guard in 01). A 0.3.0 build cannot be guarded; the README warns against downgrading.
- Existing backups are moved by the upgrade pass (owner decision 6). `LegacyLayout` never matches `@` paths.
- **Revert unit:** phases 05, 06 and 07 together. Phases 01 to 04 must stay, because 04's slot-aware resolver keeps files already in extra folders addressed correctly. Reverting 04 or 07 alone would queue extra-folder files back to the main folder (audit M4). Nothing at a destination is lost in any case.
- Phase 04 is behaviour-neutral apart from the waiting-name fix; phase 08 is text only.

## Unresolved items (answered, auto mode)

1. **Stale row re-pointing:** confirmed by the lead on 2026-11-10 (see Decisions).
2. **Downgrade to 0.3.0** cannot be blocked: the guard protects only builds from this one on.
3. **Emptied extra folders** are kept (see Decisions); revisit on owner feedback.
4. **500 moves per pass:** keep until M0-3 finalises the Drive write rate.
5. **Unnamed groups** (a group box over 300 km) share the unnamed folder; accepted.

## Changelog

- 2026-11-10: audit resolved.
  - C1: binding id → name → fallback; no re-pointing of listed rows; conflicts refused; R5 and R6.
  - I1: country-only freeze.
  - I2: binding for every kind; R3b.
  - I3: passes over all groups, reserved names, slug lengthening, fuzz (a) and (b).
  - I4: in-memory slot, primary-resource folder.
  - I5: tests E14 to E19, R7, a crash in the backlog, criterion 3.
  - M1 to M12, as in the phase files.
