---
phase: 10
title: "Hardening: recovery, reconciliation, integrity, rebuild"
status: pending
priority: P1
size: L
human_effort: 4-6h
dependencies: [07, 09]
touches:
  - Sources/PhotoVaultEngine/**
  - Tests/PhotoVaultEngineTests/**
acceptance:
  - swift test
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 10: Hardening (M5)

## Overview
Recovery from destinations (FR-51, 8.15), DB backup restore (FR-52), cloud ID backfill (FR-53), reconciliation (FR-13), integrity checks for Drive and local (FR-47, FR-76), retry of deferred/skipped, "Dựng lại view". Size: L — data-integrity critical.

## Requirements
- `CloudIdBackfill` (FR-53): each cycle, batches ≤ 500, must finish before reconciliation.
- `Reconciler` (FR-13): run FR-53 → list all assets → new ones get `inserted_at = now` and jobs; missing → `deleted_at`; update hidden/favorite; changed `modificationDate` → `edit_check_pending` + sidecar refresh; rebuild `album_member`; save new token. T4b: an unhidden photo is not new.
- `RecoveryService` (8.15): only when scan complete + FR-53 done; destination `paused(recovering)`; list app items (`pvSchema=1` on Drive; tree + sidecars locally); rebuild `remote_folder` (day folders → `promoted`, `place_name`); match in order: `pvAssetId`/`assetKey` (incl. `h:` via hash index) or alias → cloud/local ID in sidecar → fingerprint `creationDate + originalFilename + pixel size/duration` (export to compare only when ambiguous, rate-limited); matched → asset/alias, job `done`, placement from location + name, `name_alloc`; shortcuts with `pvView` + `pvAssetId` → `shortcut` table; unmatched → log, never touch; then `active` and enqueue the rest (T31, T32).
- Integrity: Drive every 7 days or on demand — list app items vs DB → `missingRemote`, report count, re-upload only after owner confirms (T20); view items: owner-deleted → `userRemoved`, unknown app-created → trash shortcut. Local per FR-76.
- Retry: deferred → pending after 24 h or on demand; skipped → pending on demand (keep `remote_id`).
- "Dựng lại view" restores the desired tree including `userRemoved`.

## Implementation Steps
1. Tests first: T31 (delete DB → recover without re-upload, views intact), T32 (rebuild library → re-attach by cloud ID), T20, T40, T43 (long sleep mid-upload → ID check before new file), recovery matching with all three strategies and `h:` keys.
2. Implement; wire into `SyncCoordinator`.

## Success Criteria
- [ ] Full `swift test` green.

## Risk Assessment
- [VERIFY] Drive listing of app files after reinstall with `drive.file`: if not visible, the zero-match guard keeps the destination paused and asks the owner (see Audit additions); documented.

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- Also depends on phase 07: crash-injection tests run the engine with the real `LocalFolderDestination` in a temp dir (no `.part` left, no duplicates, no split folders).
- T4b here: token expired + 50 new photos → all found; an unhidden photo is not new.
- Recovery triggers set `recovery_required`: empty DB with data at a destination, reused root (`pvRoot`), re-added NAS (`destination.json`), DB restore (FR-52), root/account change (FR-08), owner request.
- Zero-match guard: before going `active`, compare matched items against an independent walk of the root; if the root has content and matching is low, stay `paused(recovering)` and ask the owner. Test: listing returns 0 while the root has files → nothing enqueued.
- Archive timezone restored from `pvArchiveTZ` / `destination.json` before fingerprinting.
- Local recovery requires on-disk size = sidecar size and seeds `uploaded_hash` from the sidecar; mismatch → `missingRemote` + owner notice; queue a rate-limited SHA-256 verify of recovered files.
- FR-13 owner-triggered reconciliation and FR-47 "Khôi phục giúp tôi" are engine commands exposed to the UI.
