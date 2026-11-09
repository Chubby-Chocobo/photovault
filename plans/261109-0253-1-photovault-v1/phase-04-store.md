---
phase: 04
title: "Store: GRDB schema, repositories, backups"
status: completed
priority: P1
size: L
human_effort: 4-6h
dependencies: [03]
touches:
  - Sources/PhotoVaultStore/**
  - Tests/PhotoVaultStoreTests/**
acceptance:
  - swift test --filter PhotoVaultStoreTests
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 04: Store

## Overview
SQLite through GRDB: every table and index in spec 8.2, migrations, typed records, repositories used by the engine, and DB backups (FR-52). Size: L — schema is the persistent contract.

## Requirements
- `DatabasePool` in WAL mode under the app container; `DatabaseMigrator` with `v1` creating: `destination`, `asset` (indexes on `cloud_id`, `(placement_day, category)`, `asset_key_hash`), `asset_alias`, `name_alloc`, `album_member`, `resource`, `upload_job` (UNIQUE `destination_id, asset_key, res_type`; `res_type` for sidecars uses dedicated codes), `day_stat`, `geo_cache`, `remote_folder`, `move_job`, `device_group`, `device_model`, `view_folder_group`, `shortcut`, `activity` (capped at 500 rows, FR-63), `kv`.
- Repositories: assets (upsert, alias re-attach, placement allocation with `name_alloc` collision suffixes in one transaction), resources (staging state transitions, export counters), jobs (upsert with `ON CONFLICT DO UPDATE` rules from 8.3, ready-to-upload query `pending AND resource ready AND staging_gen = target_gen` ordered by origin priority then newest first), day stats (recount from DB, never accumulate), geo cache, remote folders, move jobs, shortcuts, device groups, activity, kv (baseline/change token, scan_state, cursor, archive_timezone, schema_version).
- Every state change goes through `JobTransitions` from Core (no duplicated rules).
- `DatabaseBackup`: `VACUUM INTO` every 24 h and before migrations, keep 7 newest; restore newest on corruption (FR-52).
- Writes before side effects: repositories expose transaction-scoped APIs the engine calls before I/O.

## Implementation Steps
1. Tests first against an in-memory `DatabaseQueue`: migrations, unique constraints, upsert semantics per 8.3, name allocation races, ready-to-upload ordering, day stat recount, activity cap, backup rotation.
2. Implement schema, records, repositories.

## Success Criteria
- [x] `swift test --filter PhotoVaultStoreTests` green.
- [x] Upsert of a `done` job with unchanged content does not change state; changed content increments `target_gen` only.

## Risk Assessment
- Schema mistakes are costly after release: `v1` migration is final once shipped; later changes are new migrations.

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- Upsert is read → `JobTransitions.upsert` → write inside one `write {}`; no 8.3 rules in SQL.
- Race tests (name allocation, concurrent upserts) run on a temp-file `DatabasePool` with concurrent writers, not an in-memory queue.
- `VACUUM INTO` runs via `writeWithoutTransaction`. Any restore (FR-52) sets `recovery_required = 1` on every destination.
- Columns added to the 8.2 schema: `upload_job.uploading_gen`, `destination.recovery_required`, `destination.status_since`, `destination.last_success_at`, `kv` since-timestamps for FR-61 duration notifications (Mac disk full since, last successful sync).
- Operations for FR-71 (add destination: scope + `baseline_at` = now; remove: delete its DB state only) and FR-08 (reset Drive destination state on root/account change).
- `session_ref` is a secret: never copied into `activity` or logs.
