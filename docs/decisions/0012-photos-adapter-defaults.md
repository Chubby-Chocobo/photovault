# 0012 Photos adapter defaults for unverified PhotoKit behaviour

- **Status:** Items 1, 2, 3, 8 and 10 accepted after M0-1b and M0-5 (2026-11-09); items 4–7 pending M0-2
- **Spec refs:** FR-12, FR-19, FR-20, FR-30, FR-34, FR-46, §8.1, §8.3, [VERIFY] markers at FR-12, FR-20, FR-30, FR-34, FR-46
- **Review trigger:** after the owner runs M0-1b, M0-2 and M0-5 ([spikes](../spikes/README.md))

## Context

The spec marks these PhotoKit behaviours as unverified (`[VERIFY]`). The implementers chose the defaults below so the code can be built and tested.

## Decision

Each default is what the code does now. The spike column says which run confirms or changes it.

| # | Default in the code | Location | Spike |
|---|---|---|---|
| 1 | "Header absent" is decided only when `CGImageSourceGetStatusAtIndex` reports complete or the whole file has arrived. A JPEG without a camera make may be read fully. | `HeaderClassifier.swift` | M0-5 |
| 2 | Bytes needed for an iCloud-only asset, the completion error after `cancelDataRequest`, and chunks delivered after cancel are unknown. The code handles them defensively. | `ResourceRequestSession.swift` (`cancel`) | M0-1b, M0-5 |
| 3 | When the answer is known on the last chunk, the request is cancelled and no `completeFile` is sent (there is no total size to report). | `PhotoKitSource+Export.swift` (`conclusive`, `readClassificationHeader`) | M0-5 |
| 4 | `PHPersistentChangeFetchResult` is iterated as a `Sequence`. `currentChangeToken` is non-optional. An unreadable archived token becomes `tokenExpired`. | `PhotoKitSource+Changes.swift` | M0-2 |
| 5 | PhotoKit error codes map as: 3105 → token expired; 3210 → change details unavailable; 3164, 3169 → network; 3072 → cancelled; 3310, 3311 → not authorized. Others become `other(code:domain:)`. | `PhotosErrorMapper.swift` | M0-2 |
| 6 | Cloud-ID mapping results that fail are skipped. The code does not check the deprecated not-found result. | `PhotoKitSource.swift` (`cloudIdentifierMappings`) | M0-2 |
| 7 | `burstIsPick` is `true` for non-burst assets. `hasAdjustments` is `true` when an `.adjustmentData` resource exists. Albums are regular user albums only (`albumRegular`); Shared Albums are excluded. | `PhotoKitSnapshotMapper.swift`, `PhotoKitSource.swift` (`albums()`) | M0-2 |
| 8 | The synchronous metadata read waits up to 30 seconds for AVFoundation to load a video. | `ImageIOMetadataReader.swift` (`videoTimeout`) | M0-5 |
| 9 | Cursor format is `offset|creationDate|localId` (split into at most three fields). | `PhotoKitSource.swift` (`fetchAllAssets`) | none (internal) |
| 10 | Write errors while streaming a resource surface as `Failure.io(code:domain:)` and the partial file is deleted. | `StreamingFileWriter.swift` | M0-1b |
| 11 | `CLGeocoder` is used without a MapKit replacement. The implementer's build on the macOS 26.5 SDK showed no deprecation warning. The source comment notes it is deprecated on newer SDKs. | `CLGeocoderReverseGeocoder.swift` | M0-6 |

## Results

- **M0-5:** item 1 holds, but only once ImageIO is told the resource's UTI. Without it a Sony ARW reads as an empty TIFF. Both readers now pass `kCGImageSourceTypeIdentifierHint`. For a RAW that ImageIO cannot read at all (a camera newer than the installed macOS), `RawCameraFallback` takes make and model from the file's TIFF directory, CR3 `CMT1` box or embedded preview. Item 3 holds: local data arrives in 1 MiB chunks. Item 8: video metadata loads in under 0.01 s.
- **M0-1b:** items 2 and 10 hold. Cancel throws `cancelled`, no partial file is left, and nothing more is delivered after the cancel. Exports are byte-exact. An iCloud-only 4.7 GB video sends progress from 4 s on, but its first data only after 131 s.

## Consequences

- If `adjustmentDataHash` returns nil (adjustment data unavailable, M0-2), `EditGate` (engine) falls back to a `mod:` marker built from `modificationDate`. A changed marker re-exports the edit, and the export takes the backfill rate limit (`ResourceGuard.tryConsumeBackfill`), as FR-46 asks. If the hash call throws, the gate waits and retries.
- Item 1 and item 3 decide how much of an iCloud-only file is downloaded to classify it. M0-5 measures that number.
- Item 11: the deprecation status should be re-checked on each SDK upgrade.
