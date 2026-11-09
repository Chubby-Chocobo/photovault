# M0-5: EXIF reading and header classification

- **Status:** run 2026-11-09 on the library (NEF and DNG added the same day) and on 24 public RAW samples; Sony or DJI video samples are not in the library
- **Spec refs:** FR-20 (classification by header), FR-34 (metadata from the primary resource), §8.5, §10 (M0-5), [VERIFY M0-5] at FR-20, [VERIFY] at FR-34 (AVFoundation keys)
- **Owner time:** 2–3 hours. **Wall time:** about 2 hours.

## Goal

Check that ImageIO reads camera make, model, lens, capture date and offset from HEIC, JPEG, ARW, NEF, CR3 and DNG files, and that AVFoundation reads the QuickTime make and model from iPhone, Sony and DJI video. Measure how many bytes classification needs for an iCloud-only photo.

## Why it matters

Rule 3 of FR-20 sends a photo to `saved` when it has no camera make or model. A wrong read would misfile every photo. The byte count decides how much of each iCloud-only photo is downloaded just to classify it.

## Preconditions

- The probe from [the shared setup](README.md#probe-setup-shared).
- `exiftool` installed (for the reference values). Install it with the package manager you use. Keep its output with the probe output.
- A set of samples: HEIC, JPEG, ARW, NEF, CR3 and DNG photos; iPhone MOV; Sony video; DJI MP4 or MOV. At least three samples per type, and at least five of them iCloud-only.

## Procedure

1. For each local sample, call `ImageIOMetadataReader().metadata(of:uti:mediaType:)` on the exported file. For videos, the same call applies. Print the `CaptureMetadata` fields.
2. Run `exiftool -json` on the same file. Compare Make, Model, LensModel, DateTimeOriginal and OffsetTime (photos), and the QuickTime make and model (video). Record each mismatch.
3. For each iCloud-only photo sample, call `readClassificationHeader(localId:type:spillTo:control:)` with `.photo`. Use `ExportControl(checkpointBytes: 1 << 20, checkpoint: { bytes in log(bytes); return true })`. Record the bytes delivered when the classifier returned its answer, and whether the answer was a camera or a missing-EXIF result.
4. Compare with the full-file export of the same asset: did the header answer match the EXIF from the full file? Record every mismatch.
5. Check a JPEG with no camera make (for example, a screenshot exported from a camera app). Record what classification says and how many bytes it read.
6. Time the video metadata call for each video sample. Record the seconds. The code waits up to 30 seconds (`ImageIOMetadataReader.videoTimeout`).
7. For edited assets, record whether `adjustmentDataHash` is non-nil (this relates to M0-2; cross-check).

## Measure

| Quantity | Expected | Observed |
|---|---|---|
| Make and Model match `exiftool` (per sample) | yes | |
| Lens and capture date match `exiftool` | yes | |
| QuickTime make and model read for video | yes | |
| Bytes read to classify an iCloud-only photo | unknown; the spike measures it | |
| Header answer matches full-file EXIF | yes | |
| Video metadata time (seconds) | under 30 | |

Duration: 2–3 hours.

## Results

Run on 2026-11-09, macOS 26.6.2, `exiftool` 13.55. Samples are identified by a hash tag, not a file name. Raw logs are outside the repo.

The library holds HEIC, Sony ARW (RAW only, no JPEG twin), JPEG, PNG, Live Photos, MOV and MP4. The owner then added two NEF and two DNG files. It has no CR3, and no Sony or DJI video small enough to fetch; those rows are skipped.

The column "Without hint" is what the code did before the fix: ImageIO reads an extensionless file and guesses its type.

| Sample | Make and model (probe / exiftool) | Lens and date match | Header bytes read | Header answer = full-file answer | Video load time (s) |
|---|---|---|---|---|---|
| ARW × 3 (before the fix) | SONY ILCE-7M4 / SONY ILCE-7M4 | yes; offset no (see below) | whole file, 35–37 MB | **no: header said "no camera"** | — |
| ARW × 3 (after the fix) | SONY ILCE-7M4 / same | yes | 1 MiB (one chunk) | yes | — |
| NEF × 2 (Nikon D7100) | match | date yes; lens: ImageIO reads "AF-S DX Nikkor 35mm f/1.8G", exiftool keeps the Nikon lens outside `LensModel` | 1 MiB | yes; without hint ImageIO guesses `public.tiff` but still finds make and model | — |
| DNG × 2 (DJI FC9113, drone) | match | yes | 1 MiB | yes; without hint ImageIO guesses `com.adobe.raw-image` correctly | — |
| HEIC × 2 (iPhone 7 Plus) | match | yes | whole file (about 1.1–1.4 MB) | yes | — |
| Live Photo still × 2 | match | yes | whole file (about 1.1 MB) | yes | — |
| JPEG, Nikon D7000 | match | yes, offset +07:00 | 1 MiB | yes | — |
| JPEG without make × 2 | empty / empty | yes | whole file (52–70 KB) | yes, "no camera" | — |
| Edited JPEG × 3 (iPhone 6) | match | yes | 1 MiB | yes | — |
| Edited PNG | empty / empty | ImageIO reads a date that exiftool's `DateTimeOriginal` lacks | whole file | yes | — |
| MOV × 3 (iPhone 7 Plus) | match | — | — | — | < 0.01 |
| MP4 × 3 (no camera tags) | empty / empty | — | — | — | < 0.01 |

`adjustmentDataHash` was non-nil for all 4 edited samples.

Conclusions:

- **Bug found and fixed: a Sony ARW lost its camera make and model.**
  - **Cause:** without a type hint, ImageIO reads an ARW as a plain TIFF and returns no properties at all. Staged files have no extension, so it gets no other clue.
  - **Impact:** the photo's category was not affected. A RAW is `camera` from scan time, because FR-20 rule 3 excludes assets with a RAW resource. But the export step stored no make or model, so the photo was missing from the by-device view and its sidecars had no camera.
  - **Correction:** an earlier version of this note said every RAW would have gone to `saved`. That was wrong.
  - **Fix:** both readers now pass the resource UTI as `kCGImageSourceTypeIdentifierHint`, and the camera is readable from the first 64 KB. Checked again on the real files: 20 of 20 header answers equal the full-file answer.
  - **Other formats in the library:** NEF keeps make and model in a standard TIFF directory, and DNG is recognised without a hint.
- **ImageIO does not return `OffsetTimeOriginal` for ARW**, though exiftool reads +07:00. The offset is not used for day placement, so nothing changes.
- **PhotoKit delivered local data in 1 MiB chunks.** Classification costs one chunk for JPEG and ARW. Small HEIC files are read whole, and that read is kept as the staged file.
- **The video metadata read is far below the 30-second timeout.**

### Other RAW formats (public samples)

The library holds only ARW, NEF and DNG. To cover other formats, the probe ran on one public-domain sample per format from [raw.pixls.us](https://raw.pixls.us/), outside Photos. The table below is that first sample set. The test corpus later took the smallest file of each format, so some cameras and sizes differ (the corpus IIQ is 69 MB, and its CR3 files are under 32 MiB); `Tests/PhotoVaultPhotosTests/Fixtures/MediaCorpus/manifest.json` lists the corpus. It used the app's own `HeaderClassifier`, fed in 1 MiB chunks, and `ImageIOMetadataReader` on an extensionless copy, each once with the UTI hint and once without. The UTI comes from `UTType(filenameExtension:)`, and exiftool gives the reference values.

| Format (sample camera) | UTI | `isRaw` | Header with hint | Without hint (old code) | Matches exiftool |
|---|---|---|---|---|---|
| ARW (Sony ILCE-7RM5) | `com.sony.arw-raw-image` | yes | camera, 1 MiB | **none** | yes |
| NEF (Nikon Z 6) | `com.nikon.raw-image` | yes | camera, 1 MiB | camera | yes |
| NEF, 14-bit lossless (Nikon Z 9) | `com.nikon.raw-image` | yes | camera, 1 MiB | **none** | yes |
| NRW (Nikon Coolpix P7800) | `com.nikon.nrw-raw-image` | yes | camera, 1 MiB | **none** | yes |
| PEF (Pentax K-r) | `com.pentax.raw-image` | yes | camera, 1 MiB | **none** | yes |
| SRW (Samsung NX1) | `com.samsung.raw-image` | yes | model only, 1 MiB | **none** | model yes; ImageIO gives no make (exiftool: SAMSUNG) |
| CR3 (Canon EOS R5 II, 7.5 MB) | `com.canon.cr3-raw-image` | yes | camera, whole file | camera, whole file | yes |
| CR3 (Canon EOS R6 III, 35 MB) | `com.canon.cr3-raw-image` | yes | camera, from the complete file (over 32 MiB) | same | yes |
| CR2 (Canon 5D Mark IV) | `com.canon.cr2-raw-image` | yes | camera, 1 MiB | camera | yes |
| CRW (Canon PowerShot G5) | `com.canon.crw-raw-image` | yes | camera, whole file | camera | yes |
| RAF (Fujifilm X-T30 III) | `com.fuji.raw-image` | yes | camera, 6 MiB | camera | yes |
| ORF (Olympus E-M5 III, OM-5 II) | `com.olympus.raw-image` | yes | camera, 1 MiB | camera | yes |
| RW2 (Panasonic DC-S5) | `com.panasonic.rw2-raw-image` | yes | camera, 1 MiB | camera | yes |
| RWL (Leica V-LUX 114) | `com.leica.rwl-raw-image` | yes | camera, 1 MiB | camera | yes |
| DNG (Leica M10, iPhone 6s Plus) | `com.adobe.raw-image` | yes | camera, 1 MiB | camera | yes |
| 3FR, FFF (Hasselblad) | `com.hasselblad.3fr-raw-image`, `…fff-raw-image` | yes | camera, 1 MiB | camera | yes |
| IIQ (Phase One IQ3 100MP, 109 MB) | `com.phaseone.raw-image` | yes | camera, from the complete file | same | yes |
| MRW (Minolta DiMAGE 7) | `com.konicaminolta.raw-image` | yes | camera, 1 MiB | camera | yes |
| DCR (Kodak DCS760C) | `com.kodak.raw-image` | yes | camera, 1 MiB | camera | yes |
| ERF (Epson R-D1) | `com.epson.raw-image` | yes | camera, 1 MiB | camera | yes |
| X3F (Sigma DP0 Quattro) | none (dynamic UTI) | no | unreadable | unreadable | macOS does not support X3F |

Conclusions:

- **The missing hint broke five formats, not only ARW:** ARW, lossless NEF from the Z 9, NRW, PEF and SRW. With the hint, every format macOS reads names its camera. The camera is in the first 16 KiB for all five.
- **Header classification does not apply to RAW.** RAW photos are `camera` from scan time. The header read classifies only photos without RAW (JPEG, HEIC, PNG):
  - a large JPEG is decided from the first 1 MiB chunk, with or without a camera;
  - a HEIC is read whole, and the download is kept as the staged copy.
- **macOS 15 cannot read the Fujifilm X-T30 III RAF; macOS 26 can.** CI runs macOS 15. A camera newer than the installed macOS gets no properties from ImageIO, so the same by-device and sidecar gap appears there.
  - The reader now falls back to the file itself when a RAW lacks make or model. It looks in the first TIFF directories (most formats), then the `CMT1` box of a CR3, then an embedded JPEG preview's Exif (RAF).
  - The fallback names the camera for 23 of the 27 corpus files without ImageIO. It cannot for CRW, IIQ and MRW, which macOS has long supported, and X3F is not RAW to the app.
  - It also supplies the make that ImageIO leaves out for Samsung SRW (SAMSUNG).
- **Sigma X3F is not supported by macOS.** It has no system UTI, so the app does not treat it as RAW, and ImageIO cannot read it.
- **Regression tests** (each checked by breaking the code on purpose: dropping the UTI in either reader, removing the fallback or one of its steps, misclassifying DNG, losing the UTI or the complete-file read on overflow, passing no UTI from the export step, raising the 32 MiB buffer limit; all ten fail):
  - `RawHeaderFixtureTests` runs on the opening bytes of 21 of these samples, kept in git (`Tests/PhotoVaultPhotosTests/Fixtures/RawHeaders/`).
  - `MediaCorpusTests` runs on 27 complete files that CI fetches by checksum. It checks `isRaw` and the camera category, the make, model and capture date the export step stores, and the fallback alone.
  - `RawCameraFallbackTests` uses synthetic bytes, so the fallback is checked whatever cameras the installed macOS knows.
  - `HeaderReadTests` drives `PhotoKitSource.headerResult` as `readClassificationHeader` does. It checks the one-chunk JPEG budget, the kept HEIC download, the 32 MiB buffer limit and the complete-file read with the UTI.

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| Header answer rule | `Sources/PhotoVaultPhotos/HeaderClassifier.swift`, `evaluate(isFinal:)` | complete status or whole file; the resource UTI is passed to ImageIO |
| Answer on the last chunk | `Sources/PhotoVaultPhotos/PhotoKitSource+Export.swift`, `conclusive` | cancel, no `completeFile` |
| Camera identity rule | `Sources/PhotoVaultCore/Models/Snapshots.swift`, `hasCameraIdentity` | make or model non-empty |
| Video metadata timeout | `Sources/PhotoVaultPhotos/ImageIOMetadataReader.swift`, `videoTimeout` | 30 seconds |
| Checkpoint interval | `Sources/PhotoVaultCore/Protocols/PhotosSource.swift`, `ExportControl.defaultCheckpointBytes` | 256 MiB |

Decisions to update: [0012](../decisions/0012-photos-adapter-defaults.md) (items 1, 3, 8). The rule that a photo with a missing camera make and model is `saved` is spec FR-20 and is not changed by this spike, unless the result shows the header read is wrong.
