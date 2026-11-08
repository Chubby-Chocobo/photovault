---
phase: 08
title: "Engine: change tracking, export, fan-out, sync cycle"
status: done
priority: P1
size: L
human_effort: 6-10h
dependencies: [04]
touches:
  - Sources/PhotoVaultEngine/**
  - Tests/PhotoVaultEngineTests/**
acceptance:
  - swift test --filter PhotoVaultEngineTests
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 08: Engine pipeline

## Overview
The M1 pipeline: `ChangeTracker → Classifier → Store → ExportWorker → fan-out → destinations` and the sync cycle of spec 8.4, built only on Core protocols and the Store, tested end to end with fakes. Size: L — the heart of the app, crash-safety invariants.

## Requirements
- `Baseline` (FR-15): take token → store baseline/change token + Drive `baseline_at` → scan.
- `Scanner` (FR-10): resumable with `scan_state` + cursor; records every asset incl. hidden/burst; `inserted_at = NULL`.
- `ChangeTracker` (FR-12): one DB transaction per `PersistentChange`, committing its token; DB-only work (no PhotoKit resource or network I/O); deletions only set `deleted_at`; unknown local IDs → alias lookup / cloud ID re-attach (8.1); token expired → reconciliation (phase 10 hook).
- `EligibilityService`: recompute jobs per destination on asset/settings/rule/scope changes; upsert or cancel per 8.3/8.8; widening enqueues from DB without rescanning (FR-19, FR-06).
- `ClassifyWorker`: provisional photos read header via `PhotosSource.readClassificationHeader`, finalize category, recompute destination set both ways (FR-20), then `PlacementAllocator` fixes placement once (8.1).
- `ExportWorker` (FR-30..34, NFR-09): only placed assets, primary first; priority incremental > refresh > reupload > backfill (newest first); export only when an available destination needs it; token bucket for backfill and re-exports (`export_count ≥ 1`); disk guard via a single `ResourceGuard` actor (FR-31, 8.5: low/critical watermarks, staging soft cap 4 GB with the single-export exception, power/thermal/Low Power gates via an injected `SystemConditions`); hashing + EXIF after export; export errors per FR-23.
- `StagingManager` (8.9.3): generation-named files, release when every available destination's job is done, idle expiry 2 h, orphan cleanup at startup (FR-32).
- `UploadRunner` (fan-out): ≤ 2 exports, ≤ 2 uploads per destination (NFR-03); layout from placement + day stat inside a transaction; `ensureFolder`; upload; verify checksum; transitions via `JobTransitions`; destination-level errors change destination status without touching `attempts` (8.14).
- `SyncCoordinator` (8.4 steps 1–11) with triggers (FR-14) abstracted as `SyncTrigger` events; observable state for the UI (per-destination status, counts, backfill progress, ETA).
- Startup recovery (8.3): `exporting` → `none`, `uploading` → resume path.
- `InstanceLock` (FR-54): exclusive `flock` on `<container>/photovault.lock`.
- `ActivityLog` (FR-63) and `os.Logger` categories with job IDs (NFR-07).

## Implementation Steps
1. Tests first with fakes: T1–T5 (T4 = scan race with new photos), T6 (burst/hidden), T14–T15 (disk/power gates), T16–T17 (crash at every step via injected failure points → no duplicates, no `.part`), T18 (flaky destination never defers), T26 (offline NAS, staging does not grow), T27/T27b/T27c, T41.
2. Implement services and coordinator.

## Success Criteria
- [ ] Engine tests green; crash-injection test leaves DB and fake destinations consistent.

## Risk Assessment
- Concurrency bugs under Swift 6 strict checking: actors per shared resource (ResourceGuard, folder creation, store writer).
- [VERIFY M0-1] watermarks/rate: defaults 15/5 GB and 20 GB/h, settings-driven.

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- T4b removed from this phase (it is reconciliation, phase 10); the scan-race test is T4. T30b moved to phase 09.
- `ClassifyWorker` goes through `ResourceGuard` (watermarks, staging cap counting kept full files, power/thermal gates and backfill bucket for non-incremental assets). T14 runs with classification active.
- FR-11: backfill only when `scan_state = complete`.
- FR-33: cancel the export stream early when every destination needing the file has exceeded its size cap.
- `StartupRecovery` resolves every unfinished state across tables: resource `exporting`, job `uploading` (probe by reserved ID first, then `session_md5` re-export compare), move jobs `inProgress` (probe old/new names), shortcuts `pending` with reserved IDs, interrupted `replaceContent`.
- The `uploading → done` transaction compares the job's parent with the current layout; a mismatch (day promoted meanwhile) creates a `move_job`.
- `UploadRunner` and `EligibilityService` skip destinations with `recovery_required` or `paused(recovering)`.
- NFR-08: scan and reconciliation run off the main actor in batches with progress; test with 50 000 fake assets under a time budget.
- Container resolution: DB, staging and lock live in the sandbox container; an unsandboxed build refuses to start unless launched with `--dev-container` (separate dev directory), so signed and unsigned builds never share or split state.
