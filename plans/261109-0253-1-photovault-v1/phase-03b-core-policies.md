---
phase: 03b
title: "Core policies: rate limiting, disk guard, places, sidecars, devices, views"
status: done
priority: P1
size: M
human_effort: 3-5h
dependencies: [03]
touches:
  - Sources/PhotoVaultCore/Policies/**
  - Sources/PhotoVaultCore/Resources/**
  - Tests/PhotoVaultCoreTests/Policies/**
acceptance:
  - swift test --filter PhotoVaultCoreTests
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 03b: Core policies

<!-- Updated: Audit 2026-11-09 - split from the original core phase so 04-07 are not blocked by engine-only policies -->

## Overview
Pure algorithms consumed only by the engine (phases 08–10). Runs in parallel with 04–07 and owns only `Policies/` and `Resources/` subfolders. Size: M — one module, many small algorithms.

## Requirements
- `Backoff` (1 s → 30 min, full jitter, injectable RNG; NFR-04), `TokenBucket` (bytes/hour, priority lanes: upload > metadata/view), `RollingByteCap` (700 GB / 24 h).
- `DiskGuardPolicy` (FR-31, 8.5): may-start (staging + in-flight < 4 GB, single-export exception), cancel at critical, resume at low + 5 GB, tooLargeForDisk after 2 cancels per the spec formula, applies to exports **and** classification reads.
- `PlaceNamingPolicy` (FR-80..83, 8.11): `GeoCell` (~0.01°), bbox > 300 km, ≤ 30 representative cells incl. extremes, same `en` key → named, locality vs province, foreign-country suffix, 6-hour end-of-day; input excludes hidden assets (when Hidden upload is off) and deleted assets.
- `SidecarBuilder` (FR-90..92, 8.12): deterministic JSON (sorted keys, fixed number format, no generation time); XMP through one XML escaper; `|` inside hierarchy segments replaced; never dates/GPS/EXIF; `"extendedMetadata":"unavailable"` on SDKs without `PHAssetExtendedMetadata`.
- `DeviceNameResolver` (FR-104) + `Resources/device-names.json`.
- `ViewRules` (FR-104..106) + `ViewDiff` (8.13).

## Implementation Steps
1. Tests first: jitter bounds, bucket refill and lanes, cap window, disk guard table incl. two concurrent exports, place cases from T28 (no GPS, two provinces, same province different city, foreign, sea, > 300 km, hidden asset excluded), sidecar determinism and escaping (`&`, `<`, `|`, U+202E), device names, view diff (create/move/trash+create/trash, `userRemoved` kept, trash/move before create).
2. Implement.

## Success Criteria
- [ ] Policy tests green; sidecar bytes identical across runs.

## Risk Assessment
- Device-name table entries are [VERIFY]: shipped as a small table, owner-editable via group rename.
