---
phase: 04
title: "Folder adapter and file metadata"
status: pending
priority: P2
size: M
human_effort: 1-2h
dependencies: [01]
touches:
  - Sources/PhotoVaultLocal/LocalFolderSource.swift
  - Sources/PhotoVaultLocal/LocalFolderSource+Listing.swift
  - Sources/PhotoVaultLocal/RootAccess.swift
  - Sources/PhotoVaultPhotos/ImageIOMetadataReader+File.swift
  - Tests/PhotoVaultLocalTests/**
  - Tests/PhotoVaultPhotosTests/**
acceptance:
  - swift test --filter LocalFolderSourceTests
  - swift test --filter FileMetadataReaderTests
  - swift test --filter PhotoVaultLocalTests
  - swift test --filter PhotoVaultPhotosTests
---

# Phase 04: Folder adapter and file metadata

## Overview
This phase builds the two adapters behind the Core protocols from phase 01. `LocalFolderSource` (`FolderImportSource`) reads a folder the owner picked, through a read-only security-scoped bookmark. `ImageIOMetadataReader` gains `FileMetadataReading`. It runs in parallel with phases 02–03 because the module files do not overlap. Size M: two modules and filesystem plus ImageIO/AVFoundation edge cases.

## Requirements
- Functional, `LocalFolderSource` (PhotoVaultLocal):
  - `init(id: SourceID, root: any RootAccess, metadata: any FileMetadataReading, queue label)`. All blocking I/O runs on its own serial `BlockingQueue` (`Sources/PhotoVaultLocal/BlockingQueue.swift:6`), per the code-standards rule for blocking file I/O.
  - `probe()`: `root.withRoot` succeeds and the directory exists. Otherwise it throws `SourceError.unavailable` (it maps `DestinationError.offline/bookmarkInvalid/rootMissing/rootTrashed`).
  - `listFiles()`: a recursive `FileManager.enumerator` with `.skipsHiddenFiles` and `.skipsPackageDescendants`. A `.photoslibrary` package, or any package, is never entered. It keeps regular files whose UTType conforms to `public.image` or `public.movie` (RAW included), plus the ignored sidecar extensions (so they can be counted as skipped), and returns `FolderFileEntry` with the relative path (NFC), UTI, size and fs dates. Symlinks are not followed.
  - `inspect(relativePath:uti:mediaType:control:)`: opens the file read-only, streams it in 1 MiB chunks into `StreamingSHA256` (honouring `control`), then calls `metadata.fileMetadata(of:)` on the URL while still inside the security scope.
  - `exportResource(locator, to:, control:)`: resolves `ImportLocator` to the relative path of the resource and copies it in chunks through the Core `StreamingFileWriter` (md5 + sha256), honouring `ExportControl`. A missing file throws `.fileMissing`, and a cancel throws `.cancelled`.
  - It never writes inside the source root: there is no create, rename or delete call in the type, and it opens files `O_RDONLY`.
- Functional, `RootAccess.swift`: `SecurityScopedBookmarkRoot.makeBookmark(for:readOnly:)` (`RootAccess.swift:64`) adds `.securityScopeAllowOnlyReadAccess` when `readOnly` is set. The default keeps today's behaviour for destinations.
- Functional, `ImageIOMetadataReader+File.swift` (PhotoVaultPhotos):
  - Images: `capture` from the existing `metadata(from:)` (`ImageIOMetadataReader.swift:49`); pixel size from `kCGImagePropertyPixelWidth/Height` as stored (the fingerprint in phase 05 compares the pair in either order, because whether `PHAsset.pixelWidth` applies the EXIF orientation is `[UNVERIFIED]`); GPS (`kCGImagePropertyGPSDictionary`, signed by the Ref fields) into `GeoPoint`; `isScreenshot` when EXIF `UserComment` trimmed equals "Screenshot" (case-insensitive); `contentIdentifier` from the MakerApple dictionary key `17`.
  - Videos: duration and natural size (transform applied); `captureDate` from `quickTimeMetadataCreationDate`, else `commonKeyCreationDate`; location from `quickTimeMetadataLocationISO6709`; make/model as today; `contentIdentifier` from `com.apple.quicktime.content.identifier`. The 30 s timeout bridge is reused (`ImageIOMetadataReader.swift:75`).
  - `captureDate` for images is left nil here. Phase 05 applies `ImportDatePolicy` to `capture.dateTimeOriginal` and `offsetTime`.

## Architecture
The adapters depend only on Core. The app composes `LocalFolderSource(metadata: ImageIOMetadataReader())` (phase 06). The dependency direction of code-standards is respected: Local does not import Photos.

## Related Code Files
- Create: `Sources/PhotoVaultLocal/LocalFolderSource.swift`, `LocalFolderSource+Listing.swift`, `Sources/PhotoVaultPhotos/ImageIOMetadataReader+File.swift`
- Modify: `Sources/PhotoVaultLocal/RootAccess.swift`, and `Tests/PhotoVaultPhotosTests/Fixtures/MediaCorpus/manifest.json` when expectations are added

## Implementation Steps
1. Tests first:
   - `LocalFolderSourceTests` (temp dir + `PlainURLRoot`):
     - nested folders, hidden files and a fake `X.photoslibrary` package are skipped; `.AAE` is listed as ignored;
     - `inspect` sha256 equals `FileHashing.sha256` of the same file;
     - the export copy has the same md5 and sha256; a cancel at the first checkpoint throws `.cancelled` and leaves no file behind;
     - a removed root throws `.unavailable`, and a deleted file throws `.fileMissing`;
     - no write happens: the root's mtime is unchanged and no new entries appear.
   - `FileMetadataReaderTests`:
     - synthetic JPEG with EXIF date, offset, GPS and Make/Model built via `CGImageDestination`;
     - PNG with `UserComment` "Screenshot" gives `isScreenshot`;
     - an orientation-6 file reports its stored dimensions;
     - a corpus HEIC and MOV pair gives equal content identifiers (`MediaCorpusTests`, gated by `PHOTOVAULT_MEDIA_CORPUS`).
2. Write the listing, inspect and export. Write the read-only bookmark option.
3. Write the metadata extension.

## Success Criteria
- [ ] The new suites and the existing Local/Photos suites pass. `MediaCorpusTests` stays green when the corpus is present.
- [ ] `grep -nE "removeItem|moveItem|createDirectory|O_WRONLY|O_RDWR" Sources/PhotoVaultLocal/LocalFolderSource*.swift` finds nothing.

## Risk Assessment
- Content-identifier keys are not documented by Apple (MakerApple `17`). Wrong keys only mean Live pairs stay separate assets (the safe failure). Verify on the corpus.
- Pixel size vs PhotoKit: the fingerprint compares the unordered pair, so orientation cannot cause a miss. A RAW whose embedded size differs from PhotoKit's size can still miss (the hash then covers exported Photos assets only).
- Big folders on NAS: listing 100k entries runs on the source queue and may take minutes. It does not block the main actor, but the lane waits (see phase 05 risk).
