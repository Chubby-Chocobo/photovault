---
phase: 05
title: "Engine: folder import job"
status: completed
priority: P1
size: L
human_effort: 2-4h
dependencies: [02, 03, 04]
touches:
  - Sources/PhotoVaultEngine/ImportStage.swift
  - Sources/PhotoVaultEngine/ImportIngest.swift
  - Sources/PhotoVaultEngine/ImportDedupe.swift
  - Sources/PhotoVaultEngine/ImportCompletion.swift
  - Sources/PhotoVaultEngine/SyncCoordinator.swift
  - Sources/PhotoVaultEngine/SyncCoordinator+Imports.swift
  - Sources/PhotoVaultEngine/EngineEnvironment.swift
  - Sources/PhotoVaultEngine/EngineSnapshot.swift
  - Sources/PhotoVaultEngine/SnapshotBuilder.swift
  - Sources/PhotoVaultTestSupport/StubFileMetadataReader.swift
  - Tests/PhotoVaultEngineTests/**
acceptance:
  - swift test --filter FolderImportTests
  - swift test --filter FolderImportDedupeTests
  - swift test --filter FolderImportCrashTests
  - swift test --filter PhotoVaultEngineTests
  - swift test
---

# Phase 05: Engine folder import job

## Overview
This phase turns a `source` row into imported assets that flow through the unchanged pipeline. It covers listing, grouping, inspection, dedupe, ingest with a final category, owner commands (start, cancel), progress in `EngineSnapshot`, completion with one activity row, and crash safety. Size L: the main new behaviour, cross-module (Core, Store, Engine), with crash-safety requirements.

## Requirements
- Functional:
  - **Commands** (`SyncCoordinator+Imports.swift`, exclusive lane like the other owner commands):
    - `startFolderImport(source: any FolderImportSource, displayName:, bookmark:) -> SourceID`: inserts the `source` row (`scanning`, mode `oneTime`, kind `localFolder`, bookmark in `config_json`) **before** registering the adapter (database before side effect), then calls `env.sources.add`. It throws `EngineError.notBaselined` when no baseline is taken.
    - `cancelImport(id)`: in one transaction, `ImportItemRepository.cancelPending`; every live asset of the source with any job not `done` gets `deletedAt = now` plus `EligibilityService.recompute` (the same as `ChangeTracker.swift` deletion handling); status `cancelled`.
    - `registerSources(_ [any FolderImportSource])`: called by the app at launch for rows that are not completed or cancelled.
  - **ImportStage** (`CycleStage`, step `.classify`, so it runs inside the 3–9 loop after `classifier.runPass()` in `SyncCoordinator+Cycle.swift`). Per run, for each `scanning` source:
    1. `probe()`. On `.unavailable`, set `offline`; an `offline` source that probes OK goes back to its previous status (`scanning`, or `importing` when `listed_at` is set).
    2. If `listed_at` is nil: `listFiles()`, then `insertIgnoring` in transactions of 500, then `setListed` in the last transaction. After a restart it lists again; the inserts are idempotent.
    3. Take up to `tuning.importBatchGroups` (100) whole groups, or until `tuning.importBatchBytes` (2 GiB) have been inspected. For each group, `inspect` every file **outside** the transaction, run `FolderItemGrouper.group`, then run `ImportDatePolicy` on the primary.
    4. One write transaction per group: `ImportDedupe.check`, then `ImportIngest.ingest` or mark `duplicate`, then `AssetFinalizer.finalize` + `recount` (as `ClassifyWorker.swift` `commit`), then mark items. Unsupported or ignored files become `unsupported`. Files whose inspect failed become `failed` with a reason code (no path).
    5. No pending items left: `scanning` → `importing`.
  - Per run, for each `importing` source: when no item is `pending` and no `upload_job` of an asset with this `source_id` is `pending`/`uploading`, set it `completed` and record one activity row in the **same transaction** (`ImportCompletion`). Exactly once, because the status check is inside the transaction.
  - It returns `true` when it ingested or changed something, so the cycle keeps looping.
  - **Ingest** (`ImportIngest`): builds an `AssetSnapshot` (reused from `Sources/PhotoVaultCore/Models/Snapshots.swift:65`):
    - `localId = ImportLocator`, `cloudId nil`, `mediaType`;
    - subtypes: `photoScreenshot` when `isScreenshot`, `photoLive` for pairs;
    - `creationDate` from the date policy, `modificationDate` nil, dims, duration, `location`;
    - favorite, hidden and adjustments all false;
    - resources from the draft (uti, `originalFilename`, `isRaw`).
    The record: key `AssetKey.content(sha256: primary)`, `sourceId`, category = `CategoryClassifier.classify(…, albumTitles: ancestor folder names inside the root, headerMetadata: metadata.capture)` (never provisional), camera/lens from `capture`, `insertedAt = max(now, every destination baselineAt)` (as `ChangeTracker.swift` `stamp`). An existing asset with the same key that has `deleted_at` (a cancelled or re-run import) is revived by clearing `deletedAt` and recomputing eligibility. Resource rows come from `AssetRecordFactory.resourceRecords` (`AssetRecordFactory.swift:61`).
  - **Dedupe** (`ImportDedupe.check`, pure DB reads in the write transaction):
    - (a) a live asset with key `x:<h>` already exists;
    - (b) `liveAsset(withResourceSHA256: h)`;
    - (c) a fingerprint: live assets on the same `creation_day` whose `creation_date` is within 1 s, whose primary `original_filename` stem is equal case-insensitively, and whose pixel pair (unordered) or duration (±0.5 s for video) is equal. The date text comes from `NameFingerprint.dateText` (`LocalTreeInterpreter.swift:42`).
    A hit marks the group's items `duplicate` with `asset_key` = the match.
  - **Export check**: when the primary of an `x:` asset is exported and its sha256 differs from the key, the export fails with `SourceError.fileChanged`, which is permanent (handled by the phase 03 branch).
  - **Snapshot**: `EngineSnapshot.imports: [ImportSnapshot]` (id, displayName, status, found, processed, imported, duplicates, unsupported, failed, filesUploaded, filesTotal) built in `SnapshotBuilder` from `ImportItemRepository.counts` plus a job count by `source_id`. Completed and cancelled rows are kept and sorted newest first.
  - **Activity text** (`ImportCompletion.summaryText`, `tr` + `L10n.plural`, no names): "Đã nhập xong 1 thư mục: N file mới, D đã có sẵn, S bỏ qua, F lỗi" / "Folder import finished: N new, D already backed up, S skipped, F failed". Cancelled jobs write "Đã huỷ nhập 1 thư mục…" with the same counts.
- Non-functional:
  - No `await` inside a write closure, and the inspect I/O stays out of transactions (code standards).
  - The stage yields: bounded work per run, and the lane gets its turn at the next pass boundary.
  - NFR-01: new `CrashPoint`s `afterImportInspectBeforeCommit` and `afterImportGroupCommit` in `EngineEnvironment.swift:20`.

## Architecture
See the data flow in plan.md. The stage owns the import lifecycle. Everything after placement is the existing pipeline: export (routed in phase 03), upload, sidecars (`source` block), views, place names.

## Related Code Files
- Create: `Sources/PhotoVaultEngine/ImportStage.swift`, `ImportIngest.swift`, `ImportDedupe.swift`, `ImportCompletion.swift`, `SyncCoordinator+Imports.swift`, `Sources/PhotoVaultTestSupport/StubFileMetadataReader.swift`
- Modify: `SyncCoordinator.swift` (add the stage to `stages`, at `SyncCoordinator.swift:71`), `EngineEnvironment.swift` (tuning, crash points), `EngineSnapshot.swift`, `SnapshotBuilder.swift`

## Implementation Steps
1. Tests first. The engine tests use the **real** `LocalFolderSource` over a temp dir with `PlainURLRoot` (the engine test target already depends on PhotoVaultLocal) and `StubFileMetadataReader` keyed by file name.
   - `FolderImportTests`:
     - parity: one Photos asset and one imported file with the same date, place, make/model and name produce the same `remote_logical_parent` and the same file name stem at `FakeDestination` (stem suffix aside, the second one would collide, so compare against a fresh DB);
     - RAW+JPEG gives one asset with two jobs; a Live pair gives one asset;
     - a screenshot goes to `Screenshots/<day>`; a JPEG without make/model goes to `Saved/<day>`; no date and no fs date goes to `Unknown date`;
     - a `newOnly` destination receives imports;
     - the sidecar carries `source`;
     - cancel cancels pending jobs and keeps the done ones;
     - the completion row is recorded once over two cycles;
     - an offline root holds the job, and it resumes after the root comes back.
   - `FolderImportDedupeTests`: same bytes twice in a folder; the same folder imported twice (second job: all duplicate); a Photos asset already exported (sha match); a Photos asset still pending (fingerprint match); same stem but a different second gives no match; a revived cancelled asset.
   - `FolderImportCrashTests`: a crash at `afterImportInspectBeforeCommit` and at `afterImportGroupCommit`, then rebuild the engine on the same DB. The result has the same asset count, no duplicate jobs, and the job completes.
2. Write the dedupe and ingest (pure DB functions) and unit test them against an in-memory store.
3. Write the stage, the commands and the completion. Wire them into the coordinator.
4. Add the snapshot fields.
5. Run the full `swift test`.

## Success Criteria
- [ ] All three new suites pass, and so does the full `swift test`.
- [ ] Importing a 1,000-file fixture tree finishes in a test run with every file accounted for: found = imported + duplicate + unsupported + failed + cancelled.

## Risk Assessment
- Listing a huge NAS folder holds the lane for minutes (owner commands wait; pause is immediate). Unknown that could grow the effort: paged listing with a retained enumerator, if the owner hits this. Review after the manual test.
- A fingerprint false positive skips a real photo. It needs the same second, stem and size. Logged as a count; the owner can see the duplicates number.
- Day-stat counts and place naming: imported camera assets join `day_stat` like Photos ones, so a day named from Photos may gain photos. That is the expected behaviour: the same layout.
- Re-export after staging release needs the folder: if it is offline, it waits; if the file is gone, it becomes a `resourceMissing` skip.
