---
phase: 03
title: "Engine: source routing, Photos-only passes"
status: completed
priority: P1
size: L
human_effort: 1.5-3h
dependencies: [01, 02]
touches:
  - Sources/PhotoVaultEngine/EngineEnvironment.swift
  - Sources/PhotoVaultEngine/SourceRegistry.swift
  - Sources/PhotoVaultEngine/PhotosContentSource.swift
  - Sources/PhotoVaultEngine/ExportWorker.swift
  - Sources/PhotoVaultEngine/ExportWorker+SourceFailures.swift
  - Sources/PhotoVaultEngine/EngineQueries.swift
  - Sources/PhotoVaultEngine/Reconciler.swift
  - Sources/PhotoVaultEngine/CloudIdBackfill.swift
  - Sources/PhotoVaultEngine/EditGate.swift
  - Sources/PhotoVaultEngine/ClassifyWorker.swift
  - Sources/PhotoVaultEngine/RecoveryMatcher.swift
  - Sources/PhotoVaultEngine/SidecarPlanner.swift
  - Sources/PhotoVaultTestSupport/FakeContentSource.swift
  - Tests/PhotoVaultEngineTests/**
acceptance:
  - swift test --filter SourceRoutingTests
  - swift test --filter PhotosOnlyPassesTests
  - swift test --filter PhotoVaultEngineTests
---

# Phase 03: Engine source routing, Photos-only passes

## Overview
This phase makes the engine safe for assets that do not come from Photos, before any import code exists. Content reads go through a registry keyed by `asset.source_id`, Photos-only passes ignore other sources, and an offline source stops only its own exports. Size L: it changes the shared `EngineEnvironment` and touches seven engine passes.

## Requirements
Exact call sites that become source-aware (re-verified on `feat/17-multiple-sources`):

| Site | Today | Change |
|---|---|---|
| `ExportWorker.swift:197` | `env.photos.exportResource(localId:type:to:control:)` | `await env.sources.content(for: asset.sourceId)?.exportResource(locator, …)`. A missing source throws `SourceError.unavailable`. |
| `ExportWorker.swift:227-232` `handleFailure` | classifies only `PhotosSourceError`; a `destinationLevel` error sets `photosLost` (ends the pass) | `SourceError` branch in `ExportWorker+SourceFailures.swift`. `.unavailable` sets the source row to `offline` and resets the export with `retryAt`, and does **not** set `photosLost`. `.cancelled` takes the existing cancel path. Permanent errors take the existing permanent path. |
| `EngineQueries.swift:127-146` `exportCandidates` | every placed asset | `AND NOT EXISTS (SELECT 1 FROM source s WHERE s.id = a.source_id AND s.status IN ('offline','cancelled'))` |
| `RecoveryMatcher.swift:93` index and `:204` disambiguate export | `env.photos.exportResource(localId: info.localId …)` | select `source_id` and route through `env.sources` |
| `Reconciler.swift:114-116` `markGone` | every live asset not listed by Photos gets `deleted_at` | `WHERE deleted_at IS NULL AND source_id = 'photos'` (**this is the High risk**) |
| `CloudIdBackfill.swift:39` | `cloud_id IS NULL AND deleted_at IS NULL` | add `AND source_id = 'photos'` |
| `EditGate.swift:54` `decide` | calls `env.photos.adjustmentDataHash` when `hasAdjustments` | `guard asset.sourceId == .photos` first (imports never have adjustments, defensive) |
| `ClassifyWorker.swift:82` `loadWork` | every provisional asset | return nil unless `asset.sourceId == .photos` (imports are never provisional, defensive) |
| `SidecarPlanner.swift:25` `SidecarFactory.build` | builds `SidecarInput` | for non-Photos assets, add `SidecarSource` from `ImportItemRepository.primary(assetKey)` and `SourceRepository.fetch` |

These stay unchanged and Photos-only by construction: `Scanner.swift:31,67`, `Baseline.swift:21`, `ChangeTracker.swift:44,62,65,70` (deletions are matched by PhotoKit local id, which never matches an import locator), `SyncCoordinator+Cycle.swift:98` (the cycle still needs Photos access; see the decision in plan.md), `Reconciler.swift:38-71`.

- `SourceRegistry` (actor, mirrors `DestinationRegistry` at `EngineEnvironment.swift:6`): `content(for: SourceID) -> (any ContentSource)?`, `folder(for:) -> (any FolderImportSource)?`, `add`, `remove`. It always holds `PhotosContentSource(photos)` under `.photos`.
- `EngineEnvironment.sources: SourceRegistry`. The init parameter `sources: SourceRegistry? = nil` defaults to a Photos-only registry, so every existing `EngineEnvironment(...)` call in tests compiles unchanged.
- `PhotosContentSource` maps `ResourceLocator` to `photos.exportResource(localId:type:…)` with no behaviour change.

## Architecture
```
ExportWorker / RecoveryMatcher ──► env.sources.content(for: asset.sourceId)
                                    ├─ .photos  → PhotosContentSource → PhotoKitSource (unchanged)
                                    └─ folder-* → LocalFolderSource (phase 04)
```

## Related Code Files
- Create: `Sources/PhotoVaultEngine/SourceRegistry.swift`, `PhotosContentSource.swift`, `ExportWorker+SourceFailures.swift`, `Sources/PhotoVaultTestSupport/FakeContentSource.swift`
- Modify: the files in the table above, plus `EngineEnvironment.swift`

## Implementation Steps
1. Tests first:
   - `PhotosOnlyPassesTests`: seed a live asset `x:<h>` with `source_id = folder-…`, then (a) run reconciliation and expect it to stay live, (b) run the cloud-id backfill and check that `FakePhotosSource` never sees its locator, (c) set `edit_check_pending` and expect no PhotoKit call, (d) make it provisional and check that classify skips it.
   - `SourceRoutingTests`: an export of a folder asset reads from `FakeContentSource` and not from `FakePhotosSource`. A Photos asset still reads from `FakePhotosSource`. `.unavailable` sets the source `offline`, and Photos exports in the same pass continue (`photosUnavailable == false`). An offline source's assets are not candidates.
   - Sidecar test: a non-Photos asset gets the `source` block, and a Photos asset's sidecar bytes are unchanged.
2. Add `SourceRegistry`, `PhotosContentSource` and the env field.
3. Route `ExportWorker` and `RecoveryMatcher`. Add the failure branch.
4. Add the Photos-only filters. Wire the sidecar source.
5. Run the whole `PhotoVaultEngineTests` suite (crash-recovery and integrity suites included).

## Success Criteria
- [ ] The new suites pass. Every existing engine test passes without edits to its expectations.
- [ ] `grep -n "env.photos\." Sources/PhotoVaultEngine` lists only the Photos-only sites named above.

## Risk Assessment
- High: a missed Photos-only site. Mitigation: the grep check above, plus the test that seeds a folder asset in every pass.
- `photosLost` semantics: a folder error must never end the pass for Photos. This is covered by a test.
- Unknown: `RecoveryMatcher` budget accounting when a source is offline. Treat it as an export failure of the candidate (existing `catch` at `RecoveryMatcher.swift:209-213`).
