---
phase: "06"
title: "Engine: move crash points, pass cap, late arrivals"
status: pending
priority: P2
size: M
human_effort: 1-2h
dependencies: ["05"]
touches:
  - Sources/PhotoVaultEngine/MoveWorker.swift
  - Sources/PhotoVaultEngine/EngineEnvironment.swift
  - Sources/PhotoVaultEngine/AssetFinalizer.swift
  - Tests/PhotoVaultEngineTests/CrashRecoveryTests.swift
  - Tests/PhotoVaultEngineTests/LocalRecoveryTests.swift
  - Tests/PhotoVaultEngineTests/SplitDayMoveTests.swift
acceptance:
  - swift test --filter SplitDayMoveTests
  - swift test --filter CrashRecoveryTests
  - swift test --filter LocalRecoveryTests
  - swift test
---

# Phase 06: moves and late arrivals

## Overview

Size M: three engine files and a test seam. The phase proves that split moves are crash-safe, keeps rounds short, and lands late assets in their folder without a move.

## Requirements

- `CrashPoint` (`EngineEnvironment.swift:20`) gains two cases:
  - `afterMoveStarted`: right after `MoveJobRepository.start` is persisted.
  - `afterMoveBeforeCommit`: after the destination call in `moveFile` and `renameFolder`, before `MoveCommit`.
  - Add both to the exclusion filters at `CrashRecoveryTests.swift:52` and `LocalRecoveryTests.swift:132`.
- `EngineTuning.maxMovesPerPass = 500` (`EngineEnvironment.swift:44`). `MoveWorker.runDestination` (`MoveWorker.swift:54`) takes the oldest that many pending jobs. The cycle repeats rounds while there is progress (`SyncCoordinator+Cycle.swift:149-190`), so nothing stalls.
- Late arrivals (audit M7). In `PlacementAllocator.place` (`AssetFinalizer.swift:11`), for a camera asset on a real day where `DayPlaceRepository.exists(day)`:
  1. The asset's cell has a cached `en` identity whose key equals `day_stat.place_key`: the main slot (NULL). If it equals a row's `place_key`: that row's slot.
  2. Otherwise, the `place_slot` of the live camera asset of that day nearest in creation time, a tie going to the earlier one.
  3. With no candidate, NULL.

  The asset has no file yet, so this moves nothing; `PlaceNamer` corrects it later if needed.

## Tests first (`SplitDayMoveTests`)

1. Two points × three targets (Drive fake, NAS fake, real local). Set up E1 with uploads done and moves pending, crash, rebuild over the same database, settle. Expect:
   - each file exactly once, in its group folder;
   - no `.part` file;
   - every `move_job` done, none failed;
   - `remote_logical_parent` equals the slot path, and on local `remote_id` equals the new path.
2. `afterFolderIdPersisted` and `afterFolderCreated` while the first move creates the NB folder: one folder.
3. Cap of 2 with 5 pending moves: three passes, at most 2 each, all done.
4. Upgrade backlog under the cap (E9 with 20 assets, cap 5): crash at `afterMoveBeforeCommit` on the third pass, restart, settle. Every file is in its folder, nothing is duplicated, and no move job is failed (audit I5).
5. Late no-GPS photo 5 minutes after an NB photo: it uploads straight into the NB folder with zero `moveFile` jobs.
6. Late GPS photo from HN taken right after an NB photo: it goes straight to main (key mapping) with zero `moveFile` jobs.
7. A stale move whose slot flipped back before it ran is discarded with no destination call (the `FakeDestination` call log).

## Risks

- A crash point inside `renameFolder` could disturb existing rename tests. Run `DayFolderTests` and `PlaceNameTests`.

## Rollback

Revert together with 05 and 07 (plan, rollback).
