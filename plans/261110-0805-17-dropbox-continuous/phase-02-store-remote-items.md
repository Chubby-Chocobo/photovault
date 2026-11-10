---
phase: 02
title: "Store: migration and remote item queries"
status: pending
priority: P2
size: L
human_effort: 0.5-1h
dependencies: [01]
touches:
  - Sources/PhotoVaultStore/Schema.swift
  - Sources/PhotoVaultStore/Schema+ContinuousSources.swift
  - Sources/PhotoVaultStore/ImportItemRepository.swift
  - Sources/PhotoVaultStore/ImportItemRepository+Remote.swift
  - Sources/PhotoVaultStore/SourceRepository.swift
  - Tests/PhotoVaultStoreTests/ContinuousSourcesStoreTests.swift
acceptance:
  - swift test --filter ContinuousSourcesStoreTests
  - swift test --filter PhotoVaultStoreTests
---

# Phase 02: Store

## Overview
This phase stores remote ids, hashes, path keys, folded paths, first-seen times and the cursor, and adds the queries the feed and the hand-over need. Size L because it is a schema migration, though a small, additive one.

## Context
- Migrations: `Sources/PhotoVaultStore/Schema.swift:7-11` (the last one is `v5-sources`). `asset.local_id` is `UNIQUE` (`Schema.swift:56`).
- v5 DDL: `Sources/PhotoVaultStore/Schema+Sources.swift:5-42` (`import_item` primary key `(source_id, rel_path)`).
- `ImportItemRepository.insertIgnoring`, `nextGroups`, `mark`, `decode`: `Sources/PhotoVaultStore/ImportItemRepository.swift:8-19`, `:24-50`, `:52-60`, `:92-107`.
- Overlap: feat/27 registers `v6-day-place` and adds a newer-schema guard (see plan.md "Merge overlap" and "Rollback").

## Requirements
1. Migration id `continuous-sources`. It has no number, is registered after the last migration on the base at merge time, and is never renamed once a build has run it. The DDL goes in `Schema+ContinuousSources.swift`:
   ```sql
   ALTER TABLE import_item ADD COLUMN remote_id TEXT;
   ALTER TABLE import_item ADD COLUMN remote_hash TEXT;
   ALTER TABLE import_item ADD COLUMN remote_path TEXT;
   ALTER TABLE import_item ADD COLUMN path_fold TEXT;
   ALTER TABLE import_item ADD COLUMN seen_at DATETIME;
   ALTER TABLE source ADD COLUMN cursor TEXT;
   CREATE INDEX import_item_remote_id ON import_item(source_id, remote_id);
   CREATE INDEX import_item_remote_path ON import_item(source_id, remote_path);
   CREATE INDEX import_item_path_fold ON import_item(source_id, path_fold);
   ```
2. `ImportItemRepository`:
   - `insertIgnoring` and `decode` carry the new fields. `path_fold` is written as `PathFolding.fold(rel_path)` when `remote_id` is set; one-time rows leave it NULL.
   - `nextGroups` gains `readyBefore: Date? = nil`. When set, a group is offered only if `MAX(COALESCE(seen_at, 0)) <= readyBefore` over its pending members (a `GROUP BY … HAVING` in the inner query). The outer query returns every pending member of the chosen groups. Callers that pass no `readyBefore` get exactly today's SQL.
3. `ImportItemRepository+Remote.swift` (new; keeps the base file small).
   - Lookups:
     - `items(db, sourceId, remoteIds:)`;
     - `items(db, sourceId, underPathKeys:)`: exact, using `remote_path = ? OR substr(remote_path, 1, length(?) + 1) = ? || '/'`, never `LIKE`;
     - `items(db, sourceId, foldedPrefixes:)`: every row whose `path_fold` starts with a folded `dir/stem`, exact `substr`;
     - `allItems(db, sourceId)`;
     - `isFree(db, sourceId, foldedPath)`.
   - Compare-and-set writes. Each one checks `(source_id, rel_path, expected remote_id)` and returns whether it wrote:
     - `insertRemote`;
     - `resetForChange`: file fields, group key, state, `seen_at`; clears `asset_key`, `is_primary`, `date_source`, `reason`;
     - `markRemoved`: keeps `asset_key` and `is_primary`;
     - `restoreReturned`: back to `imported` with the same asset;
     - `setRemotePath`;
     - `setRemoteHash`: written at group commit.
   - Hand-over: `holders(db, assetKey, excluding: Set<(SourceID, String)>)` returns the `imported` and `duplicate` rows with that asset in sources whose status is open. `requeue(db, rows, groupSuffix:)` sets them to `pending` with `seen_at = NULL` and clears `asset_key`.
   - `requeueFailed(db, sourceId)` (`failed` → `pending`, `seen_at = NULL`) and `counts` including `removed`. `pendingReadyCount(db, sourceId, readyBefore:)` counts at the group level.
4. `SourceRepository`: `cursor(db, id)` and `setCursor(db, id, String?)`. The cursor is not a `SourceRecord` field.

## Implementation steps
1. Write the tests first (`ContinuousSourcesStoreTests`):
   - Migrate a database built with every migration before this one, plus rows. Use the migrator up to the previous id, not a hard-coded `v5`. The new columns are NULL and the rows are intact.
   - Fields round-trip, and each lookup works.
   - `substr` prefix lookups are case-sensitive and treat `%` and `_` as plain characters.
   - Group-level `readyBefore`: a pair with one old and one new member is not offered; once ready, both are.
   - Compare-and-set refuses a stale `remote_id`.
   - `markRemoved` keeps the asset.
   - `holders` skips closed sources and the excluded rows.
   - `requeueFailed`, and cursor get/set.
2. Write the migration file and its registration, then the repository code.

## Risks and rollback
- Migration order with #27 is decided at merge. The id does not change. After merging the base (or #27), run `ContinuousSourcesStoreTests` again, so the migration is tested on top of the real previous migration and under #27's newer-schema guard.
- Rollback: downgrading after a continuous source was used is not supported (plan.md "Rollback"). Reverting the code before any build has run against real data is safe.
