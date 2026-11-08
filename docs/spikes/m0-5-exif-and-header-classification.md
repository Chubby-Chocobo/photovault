# M0-5: EXIF reading and header classification

- **Status:** pending owner run
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

### Owner to fill in

| Sample | Make and model (probe / exiftool) | Lens and date match | Header bytes read | Header answer = full-file answer | Video load time (s) |
|---|---|---|---|---|---|
|  |  |  |  |  |  |

Conclusions (free text):

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| Header answer rule | `Sources/PhotoVaultPhotos/HeaderClassifier.swift`, `evaluate(isFinal:)` | complete status or whole file |
| Answer on the last chunk | `Sources/PhotoVaultPhotos/PhotoKitSource+Export.swift`, `conclusive` | cancel, no `completeFile` |
| Camera identity rule | `Sources/PhotoVaultCore/Models/Snapshots.swift`, `hasCameraIdentity` | make or model non-empty |
| Video metadata timeout | `Sources/PhotoVaultPhotos/ImageIOMetadataReader.swift`, `videoTimeout` | 30 seconds |
| Checkpoint interval | `Sources/PhotoVaultCore/Protocols/PhotosSource.swift`, `ExportControl.defaultCheckpointBytes` | 256 MiB |

Decisions to update: [0012](../decisions/0012-photos-adapter-defaults.md) (items 1, 3, 8). The rule that a photo with a missing camera make and model is `saved` is spec FR-20 and is not changed by this spike, unless the result shows the header read is wrong.
