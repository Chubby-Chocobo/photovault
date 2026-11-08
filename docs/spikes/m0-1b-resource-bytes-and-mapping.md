# M0-1b: Exported bytes, cancel behaviour and resource mapping

- **Status:** pending owner run
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

### Owner to fill in

| Sample | Resources (type, UTI, filename, isRaw) | SHA-256 matches Photos | Cancel error | Partial file left |
|---|---|---|---|---|
| RAW only |  |  |  |  |
| RAW + JPEG |  |  |  |  |
| Live Photo |  |  |  |  |
| Burst |  |  |  |  |
| Drone video |  |  |  |  |
| Edited photo |  |  |  |  |
| iCloud-only cancel |  |  |  |  |

Conclusions (free text):

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| RAW detection by UTI | `Sources/PhotoVaultPhotos/UTTypeResolver.swift`, `UTTypeResolver.isRaw` (`conforms(to: .rawImage)`) | UTI conformance |
| Resource plan (which resource goes to which kind) | `Sources/PhotoVaultCore/Rules/ResourcePlanner.swift` | per FR-21 table |
| Cancel and partial-file handling | `Sources/PhotoVaultPhotos/ResourceRequestSession.swift` (`cancel`), `StreamingFileWriter.swift` | defensive: partial file deleted |
| Checkpoint interval used for the disk check | `Sources/PhotoVaultCore/Protocols/PhotosSource.swift`, `ExportControl.defaultCheckpointBytes` | 256 MiB |

Decisions to update: [0012](../decisions/0012-photos-adapter-defaults.md) (items 2 and 10).
