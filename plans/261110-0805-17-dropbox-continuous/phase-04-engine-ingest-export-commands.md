---
phase: 04
title: "Engine: ingest, export, commands, snapshot"
status: pending
priority: P2
size: L
human_effort: 2-3.5h
dependencies: [03]
touches:
  - Sources/PhotoVaultEngine/ImportStage.swift
  - Sources/PhotoVaultEngine/ImportStage+Ingest.swift
  - Sources/PhotoVaultEngine/ImportStage+Drafts.swift
  - Sources/PhotoVaultEngine/ImportStage+Continuous.swift
  - Sources/PhotoVaultEngine/ImportReader.swift
  - Sources/PhotoVaultEngine/TransferGate.swift
  - Sources/PhotoVaultEngine/SyncCoordinator+Cycle.swift
  - Sources/PhotoVaultEngine/ExportWorker.swift
  - Sources/PhotoVaultEngine/ExportWorker+SourceFailures.swift
  - Sources/PhotoVaultEngine/EngineQueries.swift
  - Sources/PhotoVaultEngine/EngineQueries+SourceExports.swift
  - Sources/PhotoVaultEngine/RecoveryMatcher.swift
  - Sources/PhotoVaultEngine/SyncCoordinator+Imports.swift
  - Sources/PhotoVaultEngine/SyncCoordinator+ContinuousSources.swift
  - Sources/PhotoVaultEngine/EngineSnapshot.swift
  - Sources/PhotoVaultEngine/SnapshotBuilder.swift
  - Tests/PhotoVaultEngineTests/ContinuousSourceTests.swift
  - Tests/PhotoVaultEngineTests/ContinuousSourceDedupeTests.swift
  - Tests/PhotoVaultEngineTests/ContinuousSourceLifecycleTests.swift
  - Tests/PhotoVaultEngineTests/ContinuousSourceCrashTests.swift
acceptance:
  - swift test --filter "ContinuousSource"
  - swift test --filter "FolderImport|CloudImport|ImportHolds|SourceRouting|PhotosOnlyPasses|DiskAndPower"
  - swift test
---

# Phase 04: Engine ingest, export, commands, snapshot

## Overview
This phase feeds the ready rows of continuous sources through the existing import pipeline and reads their bytes by remote id. Transfers follow the network and power rules. It also adds the add and remove commands and the snapshot. Size L: cross-cutting engine changes (import stage, export, cycle gate, recovery, coordinator).

## Context
- Open-import filter (no mode check): `Sources/PhotoVaultEngine/ImportStage.swift:24-26`. `advance` is at `:43-50`.
- The ingest loop: `ImportStage+Ingest.swift:11-50`, with `nextGroups` at `:54-68`. `showDiskWait` checks `.scanning` at `:79`. The inspect call is at `:99-101`, and `commitGroup` at `:151-171`. Member marking: `ImportStage+Drafts.swift:71-77`.
- Upload network and power check: `SyncCoordinator+Cycle.swift:70-78`; the per-round call is at `:160`. Export candidates: `EngineQueries.swift:126-150`, and the candidates call at `ExportWorker.swift:121-144`.
- Export read: `ExportWorker+SourceFailures.swift:8-28`. Closed-source classification: `:37-56`. `holdSource` is at `:69-76`, and its call with the reason mapping at `ExportWorker.swift:281`.
- Recovery content read: `RecoveryMatcher.swift:206-207`.
- Resume after sign-in sends a source to `scanning`: `SyncCoordinator+Imports.swift:38-53`. `cancelImport` accepts any open non-Photos source: `:57-63`.
- Snapshot of imports only: `SnapshotBuilder.swift:38-51`. Types: `EngineSnapshot.swift:55-110`.

## Requirements
1. **Reader seam.** `ImportReader` (new) offers `probe()` and `inspect(item, mediaType, control)`. It is built from a `FolderImportSource` (by `relativePath`) or a `ContinuousSource` (by `item.remoteId`; a missing id throws `fileMissing`). `ingestBatch`, `process` and `reachable` take the reader. One-time imports build it from their folder, with no behaviour change.
2. **Continuous ingest.** Phase 03 already restricts the one-time path of `ImportStage.run` to `mode == .oneTime`. Continuous sources with status `watching` and an adapter go to `ImportStage+Continuous.ingestContinuous`:
   - It returns `false` with no probe while `TransferGate.allowsNow` is false, or while no group is ready (`pendingReadyCount(readyBefore: now − 1 h)`).
   - Otherwise it checks the cooldown, runs `reachable`, then `ingestBatch` with `readyBefore`. An empty batch returns `false` and never sets `importing`. There is never a completion row.
   - `showDiskWait` accepts `watching`.
3. **Stored hash.** In the group commit of a continuous source, each member's `remote_hash` is set to the `InspectedFile.contentHash` of the bytes read. A revived asset of a continuous source moves its `resourceMissing` skips back with `.retrySkipped`. Both live in `ImportStage+Drafts.commit`, behind `source.mode == .continuous`. When a continuous row is marked `failed` (group commit in `ImportStage+Ingest.commitGroup`), `markFailedAt` records the failure time that phase 03's daily retry reads.
4. **Transfer gate.** `TransferGate.allowsNow(env)` (new) covers network, `pauseOnExpensiveNetwork + expensive/constrained` and `allUploadsOnlyOnACPower`.
   - `SyncCoordinator.uploadsAllowedNow` calls it and keeps its `lastNetworkOK` side effect.
   - `EngineQueries.exportCandidates` gains `continuousAllowed: Bool = true`. When it is false, assets whose source has `mode = 'continuous'` are left out.
   - `ExportWorker` passes the gate's answer once per pass.
5. **Export reads by id.** For a non-Photos asset, `readResource` looks up the `remote_id` of the item at `ImportLocator(localId).sibling(named: originalFilename)`, through a helper in `EngineQueries+SourceExports.swift`. The id goes in `ResourceLocator.remoteId`; one-time imports have NULL and ignore it. The same helper builds the locator at `RecoveryMatcher.swift:207`.
6. **Holds and failures.**
   - `holdSource` covers `watching`. The reason maps `accessRevoked` → `signInRequired`, `rootChanged` → `rootChanged`, and anything else → `unavailable` (`ExportWorker.swift:281`).
   - `classifyFolderFailure`: for a `cancelled` continuous source, the result is `.permanent(.resourceMissing)` (its grant is gone).
7. **Commands.**
   - `resumeImportAfterSignIn`: an `offline` continuous source resumes to `watching`, and its holds are cleared, which also triggers the failed-row retry. `cancelImport` refuses `mode == .continuous`. `cancelImport` also hands over: after it marks an asset deleted, it calls `AssetHandover.handOver(key, excluding: the import's own rows)`, so a watched source's `duplicate` row of that asset is requeued and revives it (re-audit I-3). Revival keeps the placement, so no original is uploaded twice.
   - These go in `SyncCoordinator+ContinuousSources.swift`, in the lane:
     - `addContinuousSource(source:kind:displayName:config:)`: refuses the legacy layout and a missing baseline, as `startImport` does. It writes the row (`continuous`, `watching`, with `config.remoteRootId`), then registers the adapter.
     - `removeContinuousSource(_ id)`: only for an open continuous row. It mirrors `cancelImport`, asset by asset:
       1. Pending rows become `cancelled`.
       2. Each live asset of the source with a pending, uploading or deferred job goes through `AssetHandover.retire`, with the source's own rows excluded.
       3. Each remaining live asset of the source goes through `AssetHandover.handOver`, excluding the source's own rows (they were cancelled in step 1 and must not come back to `pending`; re-audit M-9).
       4. Camera days are recounted.
       5. The status becomes `cancelled`; cursor, `blocked_removals` and `removal_allowance` become NULL.

       The adapter is then unregistered and the holds cleared. Uploads in flight finish.
8. **Snapshot.** Add `ContinuousSourceSnapshot` with `id, kind, account, displayName, status, statusReason, checkedAt (= listed_at), found, pending, ready, imported, duplicates, failed`; `removed` rows are not counted. `EngineSnapshot.continuousSources` lists open sources only, oldest first.

## Implementation steps
1. Write the red tests in the four files below, on phase 03's `ContinuousTestKit`.
2. Do the reader seam and the transfer gate first, with the import and power suites green. Then the continuous path, export, commands and snapshot.

## Tests
- `ContinuousSourceTests`:
  - 3 files become 3 assets, with the same paths and names as an import of the same files.
  - Cycle 2:
    - 1 file is added and read only after the settle delay;
    - 1 is modified: a new asset, the old one deleted with a retired `local_id`, and both files at the destination with no overwrite;
    - 1 is deleted: its files stay;
    - 1 is renamed: no upload.
  - A modification inside the settle window ingests only the final version.
  - A pair whose members arrive in two polls is ingested as one asset.
  - Bytes changed between the feed and inspect: the stored hash is the read one, the next feed gives no action, and nothing is retired or downloaded twice.
  - An export fails with `resourceMissing`, then the file returns: the job is re-armed and uploaded.
- `ContinuousSourceDedupeTests`: the same bytes as an exported Photos asset, as an unexported Photos asset matched by the fingerprint, or as a finished one-time import are counted as duplicates. A cancelled import's live asset is taken over.
- `ContinuousSourceLifecycleTests`:
  - Transfers held (expensive network; battery with the AC rule): no inspect and no export of continuous assets, while Photos still exports.
  - Revoked at the feed or at export: held. Photos uploads continue, and the last successful sync is not failing. Sign in again: `watching`, exports released, failed rows retried.
  - `rootChanged` at export: held with that reason.
  - Remove:
    - an asset with an unfinished job is deleted and its pending jobs are cancelled;
    - a fully backed-up asset stays live, and a destination added later skips it as `resourceMissing`;
    - another watched source holding the same bytes takes it over;
    - the source gets no more `changes` calls;
    - re-adding the same files reuses every asset with no original uploaded again.
  - `cancelImport` on a continuous row is refused.
  - Cancelling a one-time import whose asset has a `duplicate` row in a watched source: the row is requeued, the watched source revives the asset, and no original is uploaded twice.
  - Hand-over end to end: in-source copy (`/A` deleted, `/B` revives the asset with no upload); RAW deleted, JPEG kept (the JPEG is backed up as its own asset, at most one extra upload); a second watched folder takes the asset over with no upload.
  - A one-time import runs next to a continuous source and completes with exactly one activity row. Snapshot counts are right.
- `ContinuousSourceCrashTests`: `afterImportInspectBeforeCommit` and `afterImportGroupCommit` on a continuous source leave no duplicate asset or upload. A crash during the export of a continuous asset resumes.

## Risks and rollback
- This phase carries the plan's highest regression risk (shared import, export and cycle code). Mitigations:
  - the mode filter;
  - the reader seam;
  - `readyBefore` and `continuousAllowed` defaults that keep today's SQL;
  - the import, routing and power suites in acceptance.
- `removeContinuousSource` on a large source is one long transaction, a known limit shared with `cancelImport`. Unknown: the owner's Dropbox library size.
- Rollback: revert. Continuous rows stay unread; downgrading after use is not supported (plan.md).
