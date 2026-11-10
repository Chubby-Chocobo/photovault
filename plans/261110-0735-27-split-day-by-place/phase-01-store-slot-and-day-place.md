---
phase: "01"
title: "Store: slot column, day_place table, move index, newer-schema guard"
status: completed
priority: P2
size: L
human_effort: 1-2h
dependencies: []
touches:
  - Sources/PhotoVaultStore/Schema.swift
  - Sources/PhotoVaultStore/Schema+DayPlace.swift
  - Sources/PhotoVaultStore/Store.swift
  - Sources/PhotoVaultStore/DayPlaceRepository.swift
  - Sources/PhotoVaultStore/AssetRepository.swift
  - Sources/PhotoVaultStore/AssetPlacementRepository.swift
  - Sources/PhotoVaultCore/Entities/AssetRecord.swift
  - Sources/PhotoVaultCore/Entities/DayPlace.swift
  - Tests/PhotoVaultStoreTests/DayPlaceStoreTests.swift
acceptance:
  - swift test --filter DayPlaceStoreTests
  - swift test --filter PhotoVaultStoreTests
---

# Phase 01: Store

## Overview

Size L because it is a schema migration, though a small one. It persists each asset's slot and the names of a day's extra folders, and it refuses databases from newer builds. Nothing reads the new data yet.

## Requirements

- Migration `v6-day-place`, registered after `v5-sources` (`Sources/PhotoVaultStore/Schema.swift:10`):
  ```sql
  ALTER TABLE asset ADD COLUMN place_slot TEXT;
  CREATE TABLE day_place (
      day TEXT NOT NULL, slot TEXT NOT NULL,
      place_key TEXT, place_name TEXT,
      PRIMARY KEY (day, slot));
  CREATE INDEX move_job_subject ON move_job(destination_id, subject);
  ```
- `AssetRecord.placeSlot: String?` (default nil) in `Entities/AssetRecord.swift`, decoded in `AssetRepository.decode` (`AssetRepository.swift:164`). `upsert` (`AssetRepository.swift:12`) never writes `place_slot`.
- `AssetPlacementRepository.setPlaceSlot(db, key:, slot:)` (one column) and `clearPlaceSlots(db)` (used by the timezone restore in 07).
- Entity `DayPlace { day, slot, placeKey?, placeName? }` in a new file `Entities/DayPlace.swift`. `OrganizationRecords.swift` is also edited by #24, so keeping it separate avoids conflicts.
- `DayPlaceRepository`:
  - `fetchAll(db, day:)` ordered by slot.
  - `save` (upsert).
  - `exists(db, day:)`.
  - `days(db) -> Set<ArchiveDay>`, the days that have any row (used by recovery).
  - `deleteAll(db)`, used only by the timezone restore before any file exists. There is no per-row delete.
- Newer-schema guard: `Store.open` (`Store.swift`) runs `migrator.hasBeenSuperseded(db)` before `migrate`. If it is true, it throws `StoreError.newerSchema` (a new case of `StoreError`, `Store.swift:4`). `AppEnvironment.openStore` already turns any error that is not corruption into the launch failure "Could not open the database" (`AppEnvironment.swift:127-129`), and `DatabaseBackup.isCorruption` must stay false for it.

## Tests first (`DayPlaceStoreTests`)

1. Migrating a v5 file keeps the asset rows. `place_slot` is NULL and `day_place` is empty.
2. `upsert` keeps a `place_slot` set by `setPlaceSlot`.
3. `DayPlaceRepository` save, update, fetch order, `days`, `deleteAll`; Vietnamese names round-trip byte-exact.
4. `AssetRecord` decodes `placeSlot`; `Codable` round-trips with and without it.
5. A file migrated with an extra fake migration `v99-future` makes `Store.open` throw `.newerSchema` and leaves the file unchanged. `DatabaseBackup.isCorruption(StoreError.newerSchema) == false`.

## Steps

Write the tests (red), then add `Schema+DayPlace.swift`, the entity, the repository, the slot setters and the guard (green).

## Risks

- Another 0.4.0 branch landing a `v6`: rename this migration before merging. `feat/24-by-lens-view` has none.
- Unknown: whether `hasBeenSuperseded` has other side effects with the in-memory store. `Store.inMemory` gets the same guard, and test 5 covers it.

## Rollback

Do not revert on its own once later phases ship (plan, Backwards compatibility). Before that, revert the commit. A v6 database keeps an unused column, table and index.
