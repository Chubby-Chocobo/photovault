# M0-1b: Exported bytes, cancel behaviour and resource mapping

- **Status:** run 2026-11-09; RAW + JPEG, burst and drone samples are not in the library
- **Spec refs:** FR-21, FR-22, FR-30, §3 (primary resource), [VERIFY M0-1b] at FR-21
- **Owner time:** 1–2 hours. **Wall time:** 1–2 hours.

## Goal

Confirm that `requestData` returns the original bytes unchanged, that a request can be cancelled, and that the resource types, UTIs and filenames map as the code expects for each kind of asset.

## Why it matters

FR-22 requires byte-for-byte originals. The RAW rule (FR-21) uses the UTI, not the resource type. The cancel behaviour decides how the disk guard stops exports (FR-31).

## Preconditions

- The probe from [the shared setup](README.md#probe-setup-shared).
- Samples available: one asset of each kind below. If a kind is missing, record it as skipped.

| Kind | Example from the owner's library |
|---|---|
| RAW only (no JPEG twin) | `.ARW`, `.NEF`, `.CR3` or `.DNG` |
| RAW + JPEG pair | the same shot, two files |
| Live Photo | still and paired video |
| Burst | several frames of one burst |
| Drone video | DJI `.MP4` or `.MOV` over 4 GB, if available |
| Edited photo | an asset with an edit and "Revert" available |

## Procedure

1. For each sample, print each `ResourceDescriptor` from `AssetSnapshot.resources` (`type`, `uti`, `originalFilename`, `isRaw`). Keep the output.
2. For each primary resource, call `exportResource(localId:type:to:control:)`. The return value is an `ExportedFile` with `size`, `md5` and `sha256`.
3. In Photos, use **File → Export → Export Unmodified Original** on the same asset. Compare the exported file's SHA-256 with the probe's value. Match by content, not by name.
4. Cancel test: call `exportResource` on a large file with `ExportControl(checkpointBytes: 64 << 20, checkpoint: { _ in false })`. Record the error thrown (expected `PhotosSourceError.cancelled`), whether the output file exists afterwards, and how many bytes were delivered before cancel.
5. Repeat step 4 on one iCloud-only asset. Record the error and any chunks delivered after cancel.

## Measure

| Quantity | Expected | Observed |
|---|---|---|
| SHA-256 equal to Photos' unmodified export | yes | |
| `isRaw` true for RAW UTIs | yes | |
| RAW-only asset: primary resource type | `.photo` | |
| Cancel error type | `PhotosSourceError.cancelled` | |
| Output file after cancel | absent | |

Duration: 1–2 hours.

## Results

Run on 2026-11-09, macOS 26.6.2. The probe compared its export with Photos' own **Export Unmodified Original**, driven by AppleScript (`export … with using originals`), by SHA-256.

| Sample | Resources (type, UTI, filename, isRaw) | SHA-256 matches Photos | Cancel error | Partial file left |
|---|---|---|---|---|
| RAW only | photo, `com.sony.arw-raw-image`, ARW, isRaw true | yes | — | — |
| RAW + JPEG | skipped: none in the library | — | — | — |
| Live Photo | photo `public.heic` + pairedVideo `com.apple.quicktime-movie` | yes, both | — | — |
| Burst | skipped: none in the library | — | — | — |
| Drone video | skipped: no DJI file; a 4.7 GB video was used for the large-file case | — | `cancelled` | no |
| Edited photo | photo + adjustmentData (`com.apple.property-list`) + fullSizePhoto; often also type 16 | — | — | — |
| JPEG | photo `public.jpeg` | yes | — | — |
| iCloud-only cancel (4.7 GB video, checkpoint 64 MiB) | — | — | `cancelled` | no |

Other measurements:

| Quantity | Observed |
|---|---|
| Resource type 16 | `com.apple.photos.apple-adjustment-envelope` (`.aae`); 120 resources, 118 on edited assets. Not uploaded (falls to `default: false` in `ResourcePlanner.isPlanned`), which is right: it describes an edit and is not media. |
| iCloud-only 4.7 GB video: first progress callback | 4 s |
| Same: first data chunk | 131 s, at about 40–50 % progress; 99 progress callbacks before it |
| Same: free space on the Mac volume during the download | did not fall (+0.1 GB); where Photos keeps the download is not visible here (M0-1 measures it over a day) |
| `locallyAvailable` (undocumented `PHAssetResource` key) | not reliable: assets it called iCloud-only exported in 0.01 s |

Conclusions:

- **Exports are byte-exact** for every kind present (ARW, JPEG, HEIC, Live Photo still and video). `isRaw` is true for ARW. The primary resource of a RAW-only asset is `.photo`.
- **Cancel works.** It throws `PhotosSourceError.cancelled` and the partial file is deleted.
- **A large iCloud download sends no data for minutes, but it does send progress.** This confirms the decision that progress counts as activity for the 15-minute stall limit. Without it, a 4.7 GB video on a 5 MB/s line would have been given up as stalled.
- **The disk guard's checkpoint cannot stop what Photos downloads before the first chunk.** It stops PhotoVault's own copy only. M0-1 decides whether this matters for disk space.

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| RAW detection by UTI | `Sources/PhotoVaultPhotos/UTTypeResolver.swift`, `UTTypeResolver.isRaw` (`conforms(to: .rawImage)`) | UTI conformance |
| Resource plan (which resource goes to which kind) | `Sources/PhotoVaultCore/Rules/ResourcePlanner.swift` | per FR-21 table |
| Cancel and partial-file handling | `Sources/PhotoVaultPhotos/ResourceRequestSession.swift` (`cancel`), `StreamingFileWriter.swift` | defensive: partial file deleted |
| Checkpoint interval used for the disk check | `Sources/PhotoVaultCore/Protocols/PhotosSource.swift`, `ExportControl.defaultCheckpointBytes` | 256 MiB |

Decisions to update: [0012](../decisions/0012-photos-adapter-defaults.md) (items 2 and 10).
