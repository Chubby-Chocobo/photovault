---
phase: 01
title: "Core: continuous source contract and change planner"
status: pending
priority: P2
size: M
human_effort: 1-2h
dependencies: []
touches:
  - Sources/PhotoVaultCore/Protocols/ContinuousSource.swift
  - Sources/PhotoVaultCore/Protocols/ContentSource.swift
  - Sources/PhotoVaultCore/Models/SourceModels.swift
  - Sources/PhotoVaultCore/Entities/SourceRecords.swift
  - Sources/PhotoVaultCore/Errors/SourceError.swift
  - Sources/PhotoVaultCore/Errors/ErrorClassifier.swift
  - Sources/PhotoVaultCore/Rules/ContinuousChangePlanner.swift
  - Sources/PhotoVaultEngine/ImportStage.swift
  - Sources/PhotoVaultEngine/ImportStage+Ingest.swift
  - Sources/PhotoVaultAppSupport/ImportProgressText.swift
  - Tests/PhotoVaultCoreTests/ContinuousChangePlannerTests.swift
  - Tests/PhotoVaultCoreTests/SourceErrorClassificationTests.swift
acceptance:
  - swift test --filter ContinuousChangePlannerTests
  - swift test --filter PhotoVaultCoreTests
  - swift build
---

# Phase 01: Core contract and change planner

## Overview
This phase adds the contract every continuous source implements, and the pure function that turns a feed into ordered row actions. Size M: a public contract change in Core (a new protocol, new enum cases, optional fields), with no schema change.

## Context
- `ContentSource` / `FolderImportSource`: `Sources/PhotoVaultCore/Protocols/ContentSource.swift:19-22`, `:83-88`. `ResourceLocator`: `:4-16`. `InspectedFile`: `:70-80`.
- `SourceStatus`: `Sources/PhotoVaultCore/Models/SourceModels.swift:72-77`. `SourceMode.continuous` already exists (`:67-70`).
- `SourceConfig`, `ImportItemState`, `ImportItem`: `Sources/PhotoVaultCore/Entities/SourceRecords.swift:4-21`, `:56-91`.
- `SourceError`: `Sources/PhotoVaultCore/Errors/SourceError.swift:4-18`. Its classification: `Sources/PhotoVaultCore/Errors/ErrorClassifier.swift:58-65`.
- Exhaustive switches outside Core that must keep compiling:
  - on `SourceStatus`: `Sources/PhotoVaultEngine/ImportStage.swift:44-49` and `Sources/PhotoVaultAppSupport/ImportProgressText.swift:9-12`;
  - on `SourceError`: `Sources/PhotoVaultEngine/ImportStage+Ingest.swift:106-131`.

  No switch on `ImportItemState` exists.
- Group key: `Sources/PhotoVaultCore/Rules/FolderItemGrouper.swift:57-63`. Numbering precedent (`stem (2).ext`): `Sources/PhotoVaultDrive/DriveImportListing.swift:37-55`.

## Requirements
1. `Protocols/ContinuousSource.swift` (new), with these types:
   - `RemoteFile { remoteId, relativePath (NFC, under the root), pathKey, uti, sizeBytes, contentHash, creationDate?, modificationDate? }`;
   - `enum RemoteRemoval { case item(remoteId:), tree(pathKey:) }`;
   - `SourceChanges { files, removals, isComplete, cursor: String? }`;
   - `protocol ContinuousSource: ContentSource { probe(); changes(since:); inspect(remoteId:uti:mediaType:control:) }`.

   Doc comments state the contract:
   - net state per `pathKey`, compacted in feed order;
   - `pathKey` is compared exactly (case-sensitive);
   - `contentHash` changes exactly with the bytes;
   - `isComplete` means anything known and not listed is gone;
   - the adapter follows its own pagination and answers a cursor reset with a complete listing;
   - the root is checked before any complete listing; a moved, replaced or deleted root throws `rootChanged` and is never reported as removals;
   - only `SourceError` is thrown, never carrying paths or ids;
   - `exportResource` reads `locator.remoteId`.
2. `ResourceLocator.remoteId: String?` (init parameter defaulting to nil). `InspectedFile.contentHash: String?` (default nil; the provider hash of the bytes read).
3. Enum and field additions:
   - `SourceStatus.watching`, included in `isOpen`;
   - `ImportItemState.removed`;
   - `SourceError.rootChanged`, classified `.destinationLevel(nil)` like `unavailable`;
   - `SourceConfig.remoteRootId: String?`;
   - `ImportItem` gains optional `remoteId`, `remoteHash`, `remotePath`, `seenAt`.
4. `PathFolding.fold(_:)`: NFC + `folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)`. It is used for slot lookups and the guard. It sits in the planner file, or in its own file if reused.
5. `Rules/ContinuousChangePlanner.swift` (new, pure):
   - Input:
     - `known: [KnownRemoteItem]` (`relativePath, remoteId?, remotePath?, remoteHash?, state, assetKey?, isPrimary`). This is the subset the engine fetched, including every folded `stem (n)` sibling of a wanted path.
     - `SourceChanges`.
   - Output: `[RemoteItemAction]` ordered by `relativePath`, removals first within a path (removed → changed → moved → returned → reuse → insert). The cases are:
     - `insert(file, relativePath)`: an unknown id. It takes its own path, or the first `stem (n).ext` not held (folded) by any non-removed row or by an earlier action of the plan.
     - `reuse(file, relativePath)`: an unknown id at the path of a removed row, or of a row this plan removes.
     - `returned(file, relativePath, restore: AssetKey?)`: a known id whose row is removed. `restore` is the row's asset when the hash is unchanged and the row is an imported primary; otherwise the row goes back to pending.
     - `moved(relativePath, pathKey)`: a known live id with the same hash and a new `pathKey`, including a case-only rename.
     - `changed(file, relativePath, supersedes: AssetKey?)`: a known live id with a new hash. `supersedes` is set only for an imported primary.
     - `removed(relativePath, supersedes: AssetKey?)`: a live row whose id is gone by `.item`, by `.tree` (exact key or `key + "/"` prefix), or by a complete listing, unless the id is listed in `files`.
   - Applying the same changes to the resulting state gives no actions.
   - The large-removal brake is not here. The stage counts the `removed` actions.

## Implementation steps
1. Write `ContinuousChangePlannerTests` first (the "Unit (Core)" row of plan.md), red.
2. Add the types and cases. Keep the build green:
   - In `ImportStage.advance`, put `.watching` in the `return false` arm (phase 04 gives it work).
   - In `ImportProgressText`, label `.watching` like `.scanning` (one-time imports never reach it).
   - In the `SourceError` switch of `ImportStage+Ingest`, treat `.rootChanged` like `.unavailable`.
3. Implement the planner; green.

## Tests
- `ContinuousChangePlannerTests`:
  - every action kind;
  - an existing `IMG (2).jpg` row forces `IMG (3).jpg`, and two colliding new files in one plan get `(2)` and `(3)`;
  - "ẢNH.jpg" collides with "ảnh.jpg";
  - a `.tree("/a/b")` removal leaves `/a/bc` and `/A/b/x` (exact case) alone;
  - a removal plus the same id listed elsewhere gives `moved`;
  - a complete listing with an unlisted pending row gives `removed(supersedes: nil)`;
  - `changed` of a duplicate row or of a companion gives `supersedes: nil`;
  - `returned` gives `restore` only with an unchanged hash;
  - per-path order (a `removed(p)` before a `reuse(p)`);
  - idempotency;
  - one `.item` case.
- `SourceErrorClassificationTests`: `rootChanged` is destination-level.

## Risks and rollback
- Phase 05 starts from this contract in parallel. Freeze `SourceChanges`, `RemoteFile` and `InspectedFile.contentHash` at the end of this phase; any later change goes to the phase 05 owner.
- Rollback: revert the commit. Nothing is persistent.
