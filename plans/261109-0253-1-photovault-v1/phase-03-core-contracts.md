---
phase: 03
title: "Core contracts: models, persisted entities, protocols, state machine, fakes"
status: pending
priority: P1
size: L
human_effort: 4-6h
dependencies: [01]
touches:
  - Sources/PhotoVaultCore/**
  - Tests/PhotoVaultCoreTests/**
  - Sources/PhotoVaultTestSupport/**
acceptance:
  - swift test --filter PhotoVaultCoreTests
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 03: Core contracts

<!-- Updated: Audit 2026-11-09 - split from the original core phase; contracts are written as code by the controller and the code is the contract -->

## Overview
Every type and protocol that crosses a module boundary, plus the pure rules other modules must not duplicate (state machine, eligibility, naming, layout, classification, error classes). The controller session writes this phase itself, as compiling code with tests; phases 04–07 build against the code, not prose. Pure policies that only the engine needs (places, sidecars, devices, views, rate limiting) are phase 03b. Size: L — the shared contract for all modules.

**Ownership rule:** phases 04–07 must not add or change types in `PhotoVaultCore`. A missing type is reported back (status NEEDS_CONTEXT) and added here by the controller.

## Requirements

`PhotoVaultCore` imports Foundation, CryptoKit and UniformTypeIdentifiers only. All public types `Sendable`; stored ones `Codable, Hashable`.

### Models
- `AssetKey` (`c:`/`l:`; `appPropertyValue` returns `h:` + 32 hex SHA-256 when `pvAssetId` key+value exceeds 124 bytes; spec 8.1, FR-43).
- `MediaType`, `MediaSubtypes` (OptionSet with PhotoKit bit values), `ResourceType` (manual `RawRepresentable` over `Int`: PhotoKit raw values, `sidecarJson = 1001`, `sidecarXmp = 1002`, `unknown(Int)`), `ResourceKind`, `AssetCategory`, `CategoryReason`.
- `AppPropertyCodec`: the only string encoding for `pvResType`, `pvKind`, `pvCategory`, `pvView`, `pvLogical` (hash when long), `pvSchema`, `pvRoot`.
- `ArchiveDay`, `PlacementDay`, `Placement`, `ScopeMode`, `GlobalSettings` (all FR-05 defaults), `DestinationRules` (FR-72).
- `DestinationID`, `DestinationKind`, `DestinationStatus` + `StatusReason` (8.9.2).
- `JobState`, `JobStateReason`, `JobOrigin` (with priority).
- `CaptureMetadata` (make, model, lens, dateTimeOriginal, offsetTime).

### Persisted entities (the Store maps these 1:1 to rows)
- `AssetRecord` (all `asset` columns of 8.2, incl. `insertedAt`, `deletedAt`, placement fields, edit fields).
- `ResourceRecord` (incl. `contentGen`, `stagingGen`, `stagingState`, `exportCount`, `exportAttempts`, `exportDeferredSince`, `bytesReceivedAtCancel`, `diskCancelCount`, `lastUsedAt`).
- `UploadJob` (all `upload_job` columns plus `uploadingGen`: the generation captured at `pending → uploading`; `done_gen = uploadingGen` at completion, never `targetGen`, so an edit during upload always triggers a refresh).
- `DestinationRecord` (scope, `baselineAt`, rules, config, account, `recoveryRequired`, `statusSince`, `lastSuccessAt`).
- `DayStat`, `GeoCacheEntry`, `RemoteFolder`, `MoveJob`, `ShortcutRecord`, `DeviceGroup`, `DeviceModel`, `ViewFolderGroup`, `ActivityEvent`.

### State machine and rules (pure, single source of truth)
- `JobTransitions.apply(_ event: JobEvent, to job: UploadJob, now: Date) -> UploadJob` covering every 8.3 row. Generation rule: `targetGen = max(targetGen, resource.contentGen)` for resource jobs (never `+1`); sidecar jobs bump their own `targetGen` when the content hash changes. Upsert semantics (8.3 "Upsert") are `JobTransitions.upsert(existing:desired:)`; the Store calls it inside one write transaction (no rules in SQL).
- `Eligibility` (8.8) and `ResourcePlanner` (FR-21, global ceiling AND rules, RAW+JPEG primary) using an injected `UTIResolver` (production uses `UTType`).
- `CategoryClassifier` (FR-20, 8.10).
- `NameSanitizer` (FR-42, also strips Unicode `Cf` and bidi controls; applied to every display component: stems, place names, device-group names), `NameStemBuilder` (FR-41), `DynamicLayout: LayoutPolicy` (FR-40).
- `ErrorClassifier` (8.14) over `DestinationError` (`unauthorized`, `reauthRequired`, `rateLimited`, `server(Int)`, `offline`, `noSpace`, `quotaExceeded`, `folderMissing(logicalPath)`, `folderTrashed(logicalPath)`, `rootMissing`, `rootTrashed`, `alreadyExists(remoteId)`, `itemRejected(String)`, `notFound`, `checksumMismatch`, `foreignFile`, `foreignModified`, `transient`). Drive and Local throw only `DestinationError`.

### Protocols
- `PhotosSource`: `authorizationStatus()`, `requestAuthorization()`, `currentChangeToken()`, `fetchAllAssets(after cursor:, limit:)`, `assets(localIds:) -> [AssetSnapshot]`, `fetchPersistentChanges(since:) throws(PhotosSourceError) -> [PersistentChange]` (`PersistentChange { token, insertedAssets, updatedAssets, deletedAssets, albumsChanged: Bool }`; errors `tokenExpired`, `changeDetailsUnavailable`, `notAuthorized`, `other`), `cloudIdentifierMappings(localIds:)` (≤ 500), `localIdentifierMappings(cloudIds:)`, `albums()`, `exportResource(localId:type:to:control:) -> ExportedFile { url, size, md5, sha256 }` where `control: ExportControl` is a lock-protected object the handler polls synchronously (`shouldCancel`, `bytesReceived`), `readClassificationHeader(localId:type:spillTo:control:) -> HeaderResult { metadata: CaptureMetadata?, complete: Bool, completeFile: ExportedFile? }`, `adjustmentDataHash(localId:) -> String?`, `metadata(of: URL, mediaType:) -> CaptureMetadata` via `MetadataReading`.
- `Destination` (8.9.1), two-step for every create so IDs are persisted before side effects:
  - `capabilities` (`supportsViews`, `supportsAppProperties`, `supportsQuota`, `supportsDescription`, `fileIdsReservable`).
  - `checkAvailability() -> DestinationStatus`, `reserveIds(count:kind:) -> [RemoteID]` (Drive `generateIds`; Local returns deterministic path IDs).
  - `ensureFolder(FolderRequest { logicalPath, displayPath, parentRemoteId?, reservedId }) -> RemoteFolderRef`.
  - `upload(UploadRequest { job ids, reservedRemoteId, parentRemoteId, finalName, file, md5, sha256, size, appProperties, description, expectedPriorHash }, onSession: (SessionCheckpoint) async throws -> Void) -> UploadResult { remoteId, finalName, md5, parents, trashed }`; `resumeUpload(…)`, `probe(remoteId:) -> RemoteItem?` (FR-44 `files.get` first), `replaceContent(…)`.
  - `move(remoteId:fromParent:toParent:)`, `renameFolder(remoteId:logicalPath:newDisplayName:)`, `list(under:) -> AsyncThrowingStream<RemoteItem, Error>`, `quota() -> Quota?`.
  - **No delete operation.**
- `ViewDestination: Destination` (Drive only): `createShortcut(reservedId:targetId:parentId:name:appProperties:)`, `moveShortcut`, `trashShortcut`.
- `RootManaging` (Drive only): `findRoots()` (by `pvRoot=1`), `checkRoot()`, `createRoot(reservedId:name:)`, `renameRoot`, `untrash(remoteId:)`.
- `RemoteItem { remoteId, parentIds, name, size, md5?, sha256?, appProperties, kind (file|folder|shortcut), shortcutTargetId?, trashed }`.
- `ReverseGeocoding.reverseGeocode(cell: GeoCell, locale:)` — takes a cell, so only cell centres (~1 km) can be sent (FR-85).
- `Clock`, `DiskSpaceProvider` (`available`, `availableForImportantUsage` per volume), `SystemConditions` (`onACPower`, `lowPowerMode`, `thermalState`, `networkExpensive`, `networkConstrained`, `networkAvailable`), `UTIResolver`, `Transform` (identity, spec §7), `LogSink` with a `Redacted<T>` wrapper that prints `<redacted>`.

### Test support (`PhotoVaultTestSupport`)
`FakePhotosSource`, `FakeDestination` (in-memory tree; models reserved IDs, `alreadyExists`, failure injection points; fails the test if a create happens with an ID that was not reserved), `FakeGeocoder`, `TestClock`, `FakeDiskSpace`, `FakeSystemConditions`, `DestinationConformanceSuite` (shared behavioural checks run by phases 03 on the fake, 06 on Drive over a stub transport, 07 on Local in a temp dir: no delete, same hash → done, conflict `finalName`, `alreadyExists` handling, error classification).

## Implementation Steps
1. Tests first: every 8.3 row incl. `uploadingGen` rule and the "edit during upload" case; upsert idempotency (repeated triggers never push `targetGen` past `contentGen`); eligibility matrix T1–T5, T27c; classifier T29; naming (NFC, byte limits, forbidden chars, `Cf`/bidi, case collisions, Vietnamese); layout paths; `AppPropertyCodec` round trips; error classification table.
2. Implement models, entities, protocols, rules, fakes, conformance suite.

## Success Criteria
- [ ] `swift test --filter PhotoVaultCoreTests` green; every 8.3 row has a test.
- [ ] Conformance suite passes on `FakeDestination`.

## Risk Assessment
- Contract gaps found in 04–07 come back as NEEDS_CONTEXT and are fixed here, not locally.
