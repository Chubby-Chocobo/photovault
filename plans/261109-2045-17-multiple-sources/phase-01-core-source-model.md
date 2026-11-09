---
phase: 01
title: "Core source model and identity"
status: pending
priority: P2
size: M
human_effort: 1-2h
dependencies: []
touches:
  - Sources/PhotoVaultCore/Models/AssetKey.swift
  - Sources/PhotoVaultCore/Models/SourceModels.swift
  - Sources/PhotoVaultCore/Entities/AssetRecord.swift
  - Sources/PhotoVaultCore/Entities/SourceRecords.swift
  - Sources/PhotoVaultCore/Protocols/ContentSource.swift
  - Sources/PhotoVaultCore/Errors/SourceError.swift
  - Sources/PhotoVaultCore/Errors/ErrorClassifier.swift
  - Sources/PhotoVaultCore/Policies/StreamingFileWriter.swift
  - Sources/PhotoVaultCore/Policies/SidecarInput.swift
  - Sources/PhotoVaultCore/Policies/SidecarJSON.swift
  - Sources/PhotoVaultCore/Rules/FolderItemGrouper.swift
  - Sources/PhotoVaultCore/Rules/ImportDatePolicy.swift
  - Sources/PhotoVaultPhotos/StreamingFileWriter.swift
  - Sources/PhotoVaultPhotos/PhotosErrorMapper.swift
  - Tests/PhotoVaultCoreTests/**
  - Tests/PhotoVaultPhotosTests/**
acceptance:
  - swift test --filter PhotoVaultCoreTests
  - swift test --filter PhotoVaultPhotosTests
---

# Phase 01: Core source model and identity

## Overview
This phase adds the contracts every later phase builds on: source ids and records, content-addressed asset keys, the content-source protocols, source errors, the file grouping and date rules, and the sidecar `source` block. It has no engine behaviour yet. Size M: Core only, but it changes public contracts (`AssetKey`, `AssetRecord`, sidecar) and moves the shared streaming writer.

## Requirements
- Functional:
  - `SourceID` (string-backed, `Codable`, `Comparable`). `.photos` is the constant `"photos"`, and `.folder(UUID)` gives `"folder-<uuid lowercased>"`. `SourceKind` is `photos | localFolder` (later cases get added by deferred phases). `SourceMode` is `continuous | oneTime`. `SourceStatus` is `scanning | importing | offline | completed | cancelled`.
  - `AssetKey` (`Sources/PhotoVaultCore/Models/AssetKey.swift:7`): accept the prefix `x:` in `init?(rawValue:)` (line 10). Add `static func content(sha256:)` (lowercase 64-hex, validated) and `var isContent`. `isCloud`, `identifier`, `hashedForm` and `appPropertyValue` keep their current behaviour. `x:` + 64 hex fits `pvAssetId` (75 ≤ 124 bytes).
  - `AssetRecord` (`Sources/PhotoVaultCore/Entities/AssetRecord.swift:4`): new `sourceId: SourceID`, defaulting to `.photos` in the initializer so the existing call sites still compile.
  - `ImportLocator` (in `SourceModels.swift`): `localId = "<sourceId>/<relative path of primary, NFC>"`. It parses back to `(sourceId, relativePath)`. A resource's path = the primary's directory + `originalFilename`, because every file of a group sits in one directory.
  - Entities (`SourceRecords.swift`): `SourceRecord` (id, kind, mode, displayName, config: `bookmark: Data?`, status, statusReason, createdAt, listedAt, finishedAt) and `ImportItem` (sourceId, relativePath, groupKey, sizeBytes, modifiedAt, state `pending|imported|duplicate|unsupported|failed|cancelled`, assetKey?, isPrimary, dateSource?, reason?).
  - Protocols (`ContentSource.swift`):
    - `ResourceLocator { sourceId, localId, type, originalFilename }`.
    - `protocol ContentSource: Sendable { var id: SourceID { get }; func exportResource(_: ResourceLocator, to: URL, control: ExportControl) async throws -> ExportedFile }`.
    - `protocol FolderImportSource: ContentSource { func probe() async throws; func listFiles() async throws -> [FolderFileEntry]; func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile }`.
    - `FolderFileEntry { relativePath, uti, sizeBytes, creationDate?, modificationDate? }`, `InspectedFile { size, sha256, metadata: FileMetadata }`.
    - `protocol FileMetadataReading: Sendable { func fileMetadata(of: URL, uti: String, mediaType: MediaType) -> FileMetadata }`. This is separate from `MetadataReading` (`Sources/PhotoVaultCore/Protocols/PhotosSource.swift:169`), so existing fakes are not touched.
    - `FileMetadata { capture: CaptureMetadata, captureDate: Date?, pixelWidth, pixelHeight, duration, location: GeoPoint?, isScreenshot, contentIdentifier: String? }`.
  - `SourceError` (`unavailable`, `fileMissing`, `fileChanged`, `cancelled`, `readFailed(code: Int)`) carries no paths. `ErrorClassifier.classify(_: SourceError)`: unavailable → `destinationLevel`, fileMissing/fileChanged → `permanent(.resourceMissing)`, readFailed → `itemLevel`.
  - Move `StreamingFileWriter` and `StreamingSHA256` from `Sources/PhotoVaultPhotos/StreamingFileWriter.swift:11` to Core as `public`, unchanged otherwise. `PhotosErrorMapper` keeps mapping `StreamingFileWriter.Failure`.
  - `FolderItemGrouper.group(_ files: [GroupInput]) -> [AssetDraft]` (pure). Group key = directory + lowercased stem. RAW + one non-RAW image → one draft (`.photo` image, `.alternatePhoto` RAW). Image + video with equal non-nil `contentIdentifier` → one draft (`.photo`, `.pairedVideo`, subtype `photoLive`). Otherwise one draft per file: image → `.photo`, video → `.video`. Ignored extensions: `aae`, `xmp`, `thm`, `json`.
  - `ImportDatePolicy.captureDate(metadata:entry:archiveTimeZone:) -> (Date?, DateSource)`. The order is EXIF `DateTimeOriginal` + offset (no offset → archive timezone), then the video `captureDate`, then `min(creationDate, modificationDate)` of the file. `DateSource` is `exif | video | fileDate`.
  - Sidecar: `SidecarInput` gets `source: SidecarSource?` (`kind`, `name`, `path`, `dateSource`). `buildJSON` (`Sources/PhotoVaultCore/Policies/SidecarJSON.swift:110`) writes `"source"` only when it is non-nil.
- Non-functional: no new dependency. Photos sidecars and appProperties stay byte-identical.

## Architecture
Core contracts only. Photos keeps `PhotosSource` exactly as is. Phase 03 wraps it in a `ContentSource` adapter, so `PhotoKitSource` does not change.

## Related Code Files
- Create: `Sources/PhotoVaultCore/Models/SourceModels.swift`, `Entities/SourceRecords.swift`, `Protocols/ContentSource.swift`, `Errors/SourceError.swift`, `Rules/FolderItemGrouper.swift`, `Rules/ImportDatePolicy.swift`, `Policies/StreamingFileWriter.swift` (moved)
- Modify: `Models/AssetKey.swift`, `Entities/AssetRecord.swift`, `Errors/ErrorClassifier.swift`, `Policies/SidecarInput.swift`, `Policies/SidecarJSON.swift`, `Sources/PhotoVaultPhotos/PhotosErrorMapper.swift` (only if the move needs a qualifier)
- Delete: `Sources/PhotoVaultPhotos/StreamingFileWriter.swift`

## Implementation Steps
1. Tests first (`Tests/PhotoVaultCoreTests/`):
   - `ContentAssetKeyTests`: round-trip `x:`, reject a bad hex length, `appPropertyValue` raw, `Codable`.
   - `FolderItemGrouperTests`: ARW+JPG, `HEIC+MOV` with a matching id, `HEIC+MOV` without one, `JPG+PNG` with the same stem, an `.AAE` ignored, case-insensitive stems, different directories.
   - `ImportDatePolicyTests`: an offset present, no offset in `Asia/Ho_Chi_Minh`, the video date, the file-date fallback.
   - `SourceErrorClassificationTests`.
   - Sidecar golden: a Photos input renders the same bytes as before. An input with `source` adds only that object.
2. Add the models, entities, protocols and errors. Make the tests pass.
3. Move `StreamingFileWriter`. Run `PhotoVaultPhotosTests` (the writer tests move with it if they test internals).
4. Add the sidecar `source` block.

## Success Criteria
- [ ] Every new suite passes, and the existing Core and Photos suites pass unchanged.
- [ ] `git diff` shows no change to the Photos sidecar golden output.

## Risk Assessment
- Moving the writer breaks `@testable` access in Photos tests. Low; fix the imports.
- Adding `sourceId` to `AssetRecord` changes `Equatable`, which comparisons in Reconciler use (`Reconciler.swift:101`). The default `.photos` keeps them equal.
- Unknown: Live content-identifier keys (MakerApple `17`, QuickTime `com.apple.quicktime.content.identifier`). The grouper only consumes `contentIdentifier`; phase 04 reads it.
