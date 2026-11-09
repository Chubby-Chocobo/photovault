---
phase: 02
title: "Store: sources schema"
status: completed
priority: P2
size: M
human_effort: 0.5-1h
dependencies: [01]
touches:
  - Sources/PhotoVaultStore/Schema.swift
  - Sources/PhotoVaultStore/Schema+Sources.swift
  - Sources/PhotoVaultStore/SourceRepository.swift
  - Sources/PhotoVaultStore/ImportItemRepository.swift
  - Sources/PhotoVaultStore/AssetRepository.swift
  - Tests/PhotoVaultStoreTests/**
acceptance:
  - swift test --filter PhotoVaultStoreTests
---

# Phase 02: Store, sources schema

## Overview
This phase adds the additive migration `v5-sources` and the repositories for sources and import items. Size M: a schema change, but additive and in one module.

## Requirements
- Functional:
  - Register `v5-sources` after `v4-provisional-index` (`Sources/PhotoVaultStore/Schema.swift:10`). Never edit `v1` to `v4`.
    ```sql
    ALTER TABLE asset ADD COLUMN source_id TEXT NOT NULL DEFAULT 'photos';
    CREATE INDEX asset_source ON asset(source_id, deleted_at);
    CREATE INDEX resource_sha256 ON resource(sha256);
    CREATE TABLE source (
      id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, mode TEXT NOT NULL,
      display_name TEXT NOT NULL, config_json TEXT NOT NULL,
      status TEXT NOT NULL, status_reason TEXT,
      created_at DATETIME NOT NULL, listed_at DATETIME, finished_at DATETIME);
    CREATE TABLE import_item (
      source_id TEXT NOT NULL, rel_path TEXT NOT NULL, group_key TEXT NOT NULL,
      uti TEXT NOT NULL, size_bytes INTEGER NOT NULL, created_at_fs DATETIME, modified_at_fs DATETIME,
      state TEXT NOT NULL DEFAULT 'pending', asset_key TEXT, is_primary INTEGER NOT NULL DEFAULT 0,
      date_source TEXT, reason TEXT,
      PRIMARY KEY (source_id, rel_path));
    CREATE INDEX import_item_group ON import_item(source_id, state, group_key);
    CREATE INDEX import_item_asset ON import_item(asset_key);
    ```
  - `AssetRepository.upsert` (`AssetRepository.swift:12`) and the row decoder (`:180`) read and write `source_id`.
  - `SourceRepository`: `insert`, `fetch(id)`, `fetchAll`, `setStatus(id, status, reason, now)`, `setListed(id, now)`, `setFinished`.
  - `ImportItemRepository`:
    - `insertIgnoring([ImportItem])`, which is `INSERT OR IGNORE` so re-listing is idempotent.
    - `nextGroups(sourceId, limit)`: pending items ordered by `group_key`, whole groups only.
    - `mark(items, state, assetKey, isPrimary, dateSource, reason)`.
    - `counts(sourceId) -> [ImportItemState: Int]`.
    - `cancelPending(sourceId)`.
    - `primary(assetKey) -> (sourceId, relPath, dateSource)?` for sidecars.
  - `ResourceRepository`/`AssetRepository` gain `liveAsset(withResourceSHA256:)`. The query uses `resource_sha256` and is joined with `asset.deleted_at IS NULL`.
- Non-functional: migration time stays O(1) apart from the index builds. Existing rows read back with `source_id = 'photos'`.

## Architecture
Destination-style split: a `source` row is the job and its config (bookmark in `config_json`, like `destination.config_json`), and an `import_item` row is one file. Counters are derived with `COUNT … GROUP BY state` and not stored (DRY).

## Related Code Files
- Create: `Sources/PhotoVaultStore/Schema+Sources.swift`, `SourceRepository.swift`, `ImportItemRepository.swift`
- Modify: `Schema.swift` (register the migration), `AssetRepository.swift`

## Implementation Steps
1. Tests first:
   - `SourcesMigrationTests`: build a DB at v4 with assets, migrate, check that every asset has `source_id = 'photos'` and the indexes exist (`PRAGMA index_list`).
   - `SourceRepositoryTests` and `ImportItemRepositoryTests`: idempotent insert, group paging never splits a group, counts, cancel.
2. Write the migration and the repositories.
3. Wire `source_id` into the asset upsert and decode.

## Success Criteria
- [ ] The store suite passes. An upgraded DB keeps every asset readable and keyed as before.
- [ ] `EXPLAIN QUERY PLAN` of the sha256 lookup uses `resource_sha256`.

## Risk Assessment
- The index build on `resource(sha256)` for a large library (about 100k rows) takes a few seconds at launch, once. Acceptable.
- An older build opening a v5 DB: GRDB ignores unknown applied migrations, and the extra column has a default. Rollback = restore `DatabaseBackup`.
