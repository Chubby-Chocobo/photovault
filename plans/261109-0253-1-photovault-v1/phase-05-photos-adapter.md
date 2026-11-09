---
phase: 05
title: "Photos adapter, export streaming, metadata reader"
status: completed
priority: P1
size: M
human_effort: 3-5h
dependencies: [03]
touches:
  - Sources/PhotoVaultPhotos/**
  - Tests/PhotoVaultPhotosTests/**
acceptance:
  - swift test --filter PhotoVaultPhotosTests
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 05: Photos adapter

## Overview
`PhotoKitSource: PhotosSource` over PhotoKit, streaming export with incremental hashing, header-only classification read, and `MetadataReader` (ImageIO/AVFoundation). Size: M — one module, Apple frameworks, logic mostly mapping.

## Requirements
- FR-04 authorization `.readWrite`; FR-10 fetch with `includeHiddenAssets` and `includeAllBurstAssets`, sorted stable by creation date + local ID, cursor-resumable in batches.
- FR-12 `fetchPersistentChanges(since:)` mapping each `PHPersistentChange` to `PersistentChange` with its own token; expired token → `PhotosSourceError.tokenExpired`.
- FR-53 `cloudIdentifierMappings(forLocalIdentifiers:)` in batches ≤ 500; `localIdentifierMappings` for re-attach.
- FR-30 `PHAssetResourceManager.requestData` with `isNetworkAccessAllowed = true`; write chunks to a file handle, MD5 (CryptoKit `Insecure.MD5`) and SHA-256 streamed; cancel by request ID; disk-guard callback every 256 MB returns continue/cancel.
- FR-20 classification read: `requestData` primary into `CGImageSourceCreateIncremental`, cancel once TIFF Make/Model are known or absent; if the whole file arrived, keep it as staging.
- FR-34 `MetadataReader`: ImageIO Make, Model, LensModel, DateTimeOriginal, OffsetTime; AVFoundation `com.apple.quicktime.make/model`; failures → empty, not errors.
- FR-46 adjustment data hash (SHA-256 of `.adjustmentData` bytes).

## Implementation Steps
1. Tests: `MetadataReader` against images generated in-test with ImageIO (JPEG/HEIC with and without TIFF Make/Model), `StreamingHasher` against known vectors, header classifier with a chunked feed.
2. Implement adapter; PhotoKit calls are thin and covered by the owner's manual T-scenarios.

## Success Criteria
- [x] Hasher and metadata tests green; adapter compiles under strict concurrency.

## Risk Assessment
- [VERIFY M0-1b/M0-5] byte-exactness, cancel behaviour, bytes needed for header on iCloud-only assets: defaults documented in `docs/decisions/`.

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- Implements the Phase 03 `PhotosSource` signatures verbatim (no renames).
- Export writer: a final class, `@unchecked Sendable`, protected by `OSAllocatedUnfairLock` (macOS 13+; `Mutex` needs 15), that writes and hashes each chunk inline in PhotoKit's handler, in order. The guard decision is read from `ExportControl` synchronously; no `Task` per chunk. Test: chunks delivered from a concurrent producer keep byte order and hashes.
- Classification header read concludes "Make/Model absent" only when `CGImageSourceGetStatus` reports complete for the properties or the full file arrived; otherwise keeps reading. Test delivers TIFF after the first N KB.
- `PHPhotosError` 3210 (change details unavailable) maps to `changeDetailsUnavailable` (engine routes to reconciliation).
- Owns `CLGeocoderReverseGeocoder: ReverseGeocoding` (geocodes the cell centre only) and `UTTypeResolver: UTIResolver`.
- FR-22: test that exported bytes equal the source bytes (round trip through the writer).
