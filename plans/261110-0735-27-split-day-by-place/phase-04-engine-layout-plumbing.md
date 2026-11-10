---
phase: "04"
title: "Engine: slot-aware LayoutResolver plumbing"
status: completed
priority: P2
size: M
human_effort: 0.5-1h
dependencies: ["01", "03"]
touches:
  - Sources/PhotoVaultEngine/LayoutResolver.swift
  - Sources/PhotoVaultEngine/MoveWorker.swift
  - Sources/PhotoVaultEngine/MoveRecovery.swift
  - Sources/PhotoVaultEngine/SidecarDelivery.swift
  - Sources/PhotoVaultEngine/StartupRecovery.swift
  - Sources/PhotoVaultEngine/RecoveryWriter.swift
  - Tests/PhotoVaultEngineTests/SplitDayLayoutResolverTests.swift
acceptance:
  - swift test --filter SplitDayLayoutResolverTests
  - swift test --filter PhotoVaultEngineTests
---

# Phase 04: LayoutResolver plumbing

## Overview

Size M: a shared helper with seven call sites. There is no behaviour change except the waiting-name fix (audit M11), because every slot is NULL until phase 05.

## Requirements

- `LayoutResolver.chain(_ db:, asset: AssetRecord, layout:)` replaces the `placement:` form (`LayoutResolver.swift:17`). The slot is `asset.placeSlot`, for a camera placement on a real day only.
  - Main slot: the name is `stat.placeName` when `placeState == .named`, **or** when it is `.waitingGeocode` and the name is non-nil. This is the M11 fix; with today's rule a folder created while waiting kept the bare date for good.
  - Extra slot: the name of the `day_place` row; a missing row means nil, giving the display `YYYY-MM-DD`.
- Update all 7 call sites (re-grep `LayoutResolver.chain(` first):
  1. `LayoutResolver.swift:31` (`plan`)
  2. `LayoutResolver.swift:54` (`UploadCompletion`)
  3. `MoveWorker.swift:125`
  4. `MoveRecovery.swift:50`
  5. `SidecarDelivery.swift:19`
  6. `StartupRecovery.swift:115`
  7. `RecoveryWriter.swift:171`
- `PlaceNamer.applyRename` keeps calling `folderChain` directly until phase 05.

## Tests first (`SplitDayLayoutResolverTests`)

1. A NULL slot resolves as before, for named, unnamed and pending days.
2. A NULL slot on a `waitingGeocode` day with a stored name "Đà Lạt" gives `<day> Đà Lạt`. A day that never had a name gives the bare date.
3. Slot `p0123456789ab` with a row "Ninh Bình" gives `camera/<day>@p0123456789ab`, `<day> Ninh Bình`. Without a row it gives `<day>`.
4. `UploadCompletion.commit` with `uploadedParent: "camera/<day>"` for an asset with a slot queues one `moveFile` to the slot path.
5. `LegacyLayout.isPresent` is false on a database that holds a `remote_folder` and an `upload_job` under `camera/<day>@p…` (audit I5).

## Risks

- A missed call site would make files move back and forth. The re-grep and test 4 cover it.
- Test 2 changes today's behaviour on purpose. Check that `PlaceNameTests` has no test that expects the bare date while waiting (re-grep `waitingGeocode` in the tests).

## Rollback

Do not revert once 05 has shipped (plan, rollback). Before that, revert the commit.
