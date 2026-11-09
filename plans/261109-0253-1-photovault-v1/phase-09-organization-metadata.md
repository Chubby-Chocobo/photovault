---
phase: 09
title: "Organization & metadata: day folders, places, sidecars, edits, views"
status: completed
priority: P1
size: L
human_effort: 5-8h
dependencies: [03b, 08]
touches:
  - Sources/PhotoVaultEngine/**
  - Tests/PhotoVaultEngineTests/**
acceptance:
  - swift test --filter PhotoVaultEngineTests
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 09: Organization & metadata (M4)

## Overview
Runs the Core policies inside the pipeline: day-folder promotion with moves, PlaceNamer with a throttled geocoder, sidecar jobs, the edit gate, and the view engine with three views. Size: L — many cooperating workers, all with fakes.

## Requirements
- Day folders (8.7): recount from DB, promote once when count > N, `move_job` for every file of that day at every destination, never demote, invariant "every file of a promoted day is in the day folder" (race during upload → move job). "Sắp xếp lại" (re-sort) reports the count before running (T10).
- `MoveWorker`: pending → inProgress → done, > 8 failures → failed; local renames use the crash-safe protocol from phase 07.
- `PlaceNamer` (FR-80..85, 8.11): triggers, `waitingGeocode`, `GeocodeScheduler` ≤ 20 req/min with backoff, cell cache `(geo_cell, locale)` forever, `en` + display locale requests, priority day-folder cells then newest; rename folders, refresh sidecars/description and By place view; toggle off disables network geocoding (FR-85). Production `CLGeocoderReverseGeocoder: ReverseGeocoding` lives in `PhotoVaultPhotos` (phase 05).
- Sidecars (FR-90..94): first generation when every original job at that destination finished; regenerate on resource done, asset updated, album change, geocode, device name/language change, reconciliation; upload only when hash changes; refuse foreign/modified files. Contents differ per destination.
- Edit gate (FR-46): separate worker; `hasAdjustments` false before and now → skip; hash `.adjustmentData`, unchanged → no export; changed → `content_gen++`, export, update edited file in place (create if missing); revert keeps the edited file. Fallback per [VERIFY M0-2]: `modificationDate` compare + rate-limited export.
- View engine (FR-100..106, 8.13): `ViewRule`s By device / Favorites / By place, desired-state diff against `shortcut` table; create only when target done; target change → trash + create; leaving view → trash; group change → move; `userRemoved` kept until "Dựng lại view"; view jobs lowest priority; view folders not subject to pause rules; device rename/merge; views disabled (not scope-raised) when Drive refuses shortcuts.
- Drive `description` updates when device names or places change.

## Implementation Steps
1. Tests first: T9 (10 camera + 8 screenshots, 11th camera → split), T10, T12, T13, T28, T30, T35–T39, geocode throttle T36.
2. Implement workers and hook them into `SyncCoordinator` steps 5–9.

## Success Criteria
- [x] Engine tests green including the scenarios above.

## Risk Assessment
- [VERIFY M0-6] CLGeocoder structured fields and throttling; downgrade to country-only when fields are missing, with an owner notice.

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- Promotion creates `move_job`s only for `done` jobs, in the same transaction that sets `promoted`; in-flight jobs are caught by the `uploading → done` check (phase 08). T9 variant with one job held in `uploading`.
- T30b here, with the real edit gate: two edits within one minute while uploading → destination has the last version.
- Geocoding sends cell centres only (`ReverseGeocoding` takes `GeoCell`); hidden (when Hidden upload is off) and deleted assets are excluded from place naming and By place.
- FR-106 "Làm mới địa danh": clear the cache, geocode again, rename.
- Crash-injection tests for move, folder rename, shortcut create and sidecar replace.
