---
phase: "05"
title: "Engine: split evaluation and move planning"
status: completed
priority: P1
size: L
human_effort: 2.5-4.5h
dependencies: ["04"]
touches:
  - Sources/PhotoVaultEngine/PlaceNamer.swift
  - Sources/PhotoVaultEngine/DaySplitWriter.swift
  - Sources/PhotoVaultEngine/OrganizationQueries.swift
  - Sources/PhotoVaultEngine/GeocodeScheduler.swift
  - Tests/PhotoVaultEngineTests/PlaceNameTests.swift
  - Tests/PhotoVaultEngineTests/SplitDayTests.swift
acceptance:
  - swift test --filter SplitDayTests
  - swift test --filter PlaceNameTests
  - swift test --filter PlaceRefreshTests
  - swift test
---

# Phase 05: split evaluation

## Overview

Size L: a cross-module behaviour change and the core of the feature. `PlaceNamer` computes groups and slots, then persists the slots, names, renames and file moves in one transaction.

## Requirements

### PlaceNamer (`PlaceNamer.swift`)

`runPass` (`:14`), first write transaction:
- **Upgrade backfill:** if `kv.place_split_backfill != 1`, mark `.place` dirty for every promoted day and set the flag.
- **Hidden basis (audit M9):** if `kv.place_hidden_basis` differs from `settings.includeHidden`, mark every promoted day dirty and store the new value.

`evaluate` (`:49`):
1. **Country-only (lead decision):** `GeocodeScheduler.countryOnlyKey` becomes `static let` with internal access. While it is 1:
   - a day with `DayPlaceRepository.exists(day)` returns false and changes nothing;
   - any other day runs today's path, `PlaceNamingPolicy.evaluate`, with its result wrapped as one group of all live assets, then `DaySplitWriter`.
2. **Otherwise:** build `PlaceAsset(id:, creationDate:)` for every camera asset of the day and run `PlaceSplitPolicy.evaluate`.
   - `.pending` and `.waitingGeocode`: unchanged.
   - `.groups`: `DaySplitWriter.apply`.
3. `applyRename` (`:81`) moves into the writer.

### DaySplitWriter (new, aim for under 200 lines)

`apply(db, day:, groups:, unassigned:, stat:, context:) -> Bool`, inside the caller's transaction:
1. **Slots:**
   - main = (`stat.placeKey`, `stat.placeName`) plus the rows of `DayPlaceRepository.fetchAll(day)`;
   - each slot's `reservedNames` are the `from_value`s of open `renameFolder` jobs for its path at any destination;
   - run `DaySlotPolicy.assign`.
2. **Main slot**
   - Used: `setPlace`. If the name changed, rename `camera/<day>` at every destination and mark the day's assets dirty (today's behaviour).
   - Unused: keep the name; the state becomes `named` if the name is non-nil, else `unnamed`.
3. **Extra slots used:** upsert the row. If the name changed, enqueue a rename of `camera/<day>@<slot>` at every destination and mark the slot's members dirty.
4. **Assets:** for each member whose slot changed (never deleted or `unassigned` assets):
   - `setPlaceSlot`;
   - for every `upload_job` with `remote_id` and `remote_logical_parent` set and `state != uploading`, enqueue `moveFile(from: remote_logical_parent, to: parentLogical(chain(asset with new slot)))`;
   - sidecar jobs are included.
5. Return whether anything changed.

### MoveJobPlanner (`OrganizationQueries.swift:57`)

- `enqueueMove`: `SELECT EXISTS(… destination_id=? AND subject=? AND op='moveFile' AND to_value=? AND state IN ('pending','inProgress'))`.
- `enqueueRename` (`:81`, audit M5): the effective name comes from `SELECT to_value … op='renameFolder' AND subject=? AND state IN (…) ORDER BY id DESC LIMIT 1`.
- Both use `move_job_subject`. `open()` is removed if nothing else uses it (re-grep).

## Tests first

Rewrite `PlaceNameTests.t28TwoProvincesGiveNoNameAndAnImportDropsAnExistingName` as `t28TwoProvincesGiveTwoFoldersAndAnImportAddsAFolder`.

`SplitDayTests` (Harness, `FakeDestination` Drive + NAS, JSON and XMP on). After every scenario: no pending or failed `move_job`.

| # | Scenario | Expect |
|---|---|---|
| E1 | 10 HN + 3 NB, 3 days ago | both destinations: `<day> Hà Nội` (`camera/<day>`) and `<day> Ninh Bình` (`@p…`); sidecars beside their originals; one "moved" activity row per destination |
| E2 | One-province day, many cells, including one uncached non-representative cell | zero `move_job`s; `day_place` empty; slots NULL; never `waitingGeocode` once named; `remote_folder` rows unchanged |
| E3 | Uploaded during the day, clock then advanced | split; NB originals and sidecars moved; HN `remote_id`s unchanged |
| E4 | Named HN day plus a folder import of 2 NB photos | HN not moved; the new NB folder holds only the imported files |
| E5 | A→B→A | two folders |
| E6 | NB photos edited to HN | they move to main; the NB folder remains; folder names unique |
| E7 | All NB photos deleted | no moves |
| E8 | NB cell not geocoded yet | no slot change; the split happens after the answer |
| E9 | Upgrade: an `unnamed` two-province day with done jobs, flag absent | split once; a second pass queues nothing |
| E10 | Two unnamed groups | one folder |
| E11 | Screenshot and saved photo on the split day | stay in their branches |
| E12 | By place and By device on, Drive | shortcut ids and parents unchanged |
| E13 | Integrity check after E1 | 0 missing, 0 mismatched |
| E14 | NAS added after E1 has settled | both folders created with their final names; no `moveFile` at the NAS |
| E15 | NAS rules exclude every HN asset | the NAS has only `<day> Ninh Bình` (`@p…`); no bare-date or HN folder at the NAS |
| E16 | Place names turned off after E1, then photos added and edited | no `move_job`, no rename |
| E17 | E1, then country-only entered (kv set plus days dirty), then province seen again and cells re-answered the same | zero `moveFile` and zero renames throughout; an unsplit two-country day stays unnamed during the mode |
| E18 | Hidden upload toggled on, with a hidden GPS photo in a third province, then off again | on: the day is re-evaluated and a third folder appears; off: that asset is regrouped by time and only its files move; folder names unique |
| E19 | Group renamed while the rename is pending at the NAS (fault on `renameFolder`), then a new group with the old name | the new group joins the renaming slot (reserved name); no second folder with that name |

## Risks

- **Long transactions:** job queries run only for assets whose slot changed. Measure E9 with 500 assets and lower the batch below 100 days if a transaction takes over 1 s.
- **Unknown:** how many multi-province days real libraries hold. The cap in 06 bounds each pass.

## Rollback

Revert phases 05, 06 and 07 together and keep 01 to 04 (plan, rollback).
