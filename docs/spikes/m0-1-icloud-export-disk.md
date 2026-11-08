# M0-1: Export of iCloud-only originals and disk behaviour

- **Status:** pending owner run
- **Spec refs:** §8.5 (disk risk), FR-30, FR-31, FR-48, T14, T15, §13 (watermarks "chỉnh sau M0-1")
- **Owner time:** about 1 hour hands-on. **Wall time:** about 25 hours (export plus 24 hours of sampling).

## Goal

Find out whether exporting originals that exist only in iCloud makes the Photos library grow, and whether Photos gives back the space later. Choose the free-space metric and the watermarks from the result.

## Why it matters

Photos in Optimize Mac Storage mode may keep every downloaded original in the library. If so, the Mac fills up during backfill. The spec's stop rule (§8.5) applies if Photos never frees the space.

## Preconditions

- The probe from [the shared setup](README.md#probe-setup-shared).
- A staging folder on the Mac's internal disk, with at least 60 GB free before the run.
- Free space at the start of the run is recorded. Stop the run if free space drops below 15 GB (the low watermark), and resume only after the owner has checked the disk.
- The library must be in Optimize Mac Storage mode, and the chosen assets must not be on this Mac.

## Procedure

1. Pick 20–50 GB of assets whose originals are only in iCloud. Photos shows the iCloud download indicator on them. Note their count and total size.
2. Record the start values:
   - `du -sk` of the library bundle (`~/Pictures/Photos Library.photoslibrary`), once.
   - Both free-space values for the staging volume and for the library volume (see Measure).
3. In the probe, for each chosen `localId`, call `PhotoKitSource().exportResource(localId:type:to:control:)` with the primary type (`.photo`, or `.video` for videos). Use `ExportControl(checkpointBytes:checkpoint:)` with a checkpoint that logs the byte count and returns `true`. Write each file to the staging folder. Do not delete them during the run.
4. Sample the values every 15 minutes for the first 2 hours after the first export starts, then every hour until 24 hours after the last export finishes.
5. At the end, record `du -sk` of the library again and list the chosen assets that are still local.

## Measure

| Quantity | How |
|---|---|
| Free space, real | `URL.resourceValues(forKeys: [.volumeAvailableCapacityKey])` on the staging volume and on the library volume |
| Free space, for important usage | `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`, same volumes |
| Library size | `du -sk` at start and end |
| Export throughput | bytes per hour from the checkpoint log |
| Originals released | whether each chosen asset is still local at 24 hours |

Duration: about 25 hours. The export itself depends on the network. 20 GB on a slow link can take many hours.

## Results

### Owner to fill in

| Time since start | Free (real), staging GB | Free (important), staging GB | Free (real), library GB | Free (important), library GB | Library size GB | Bytes exported (cumulative) |
|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |

| Question | Answer |
|---|---|
| Assets exported, count and GB |  |
| Did the library grow during export? By how much? |  |
| Were originals released, and when? |  |
| Which metric moves when space is used (real or important)? |  |
| Lowest free space reached (real, GB) |  |

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| Low watermark | `Sources/PhotoVaultCore/Models/Settings.swift`, `GlobalSettings.lowWatermarkBytes` | 15 GiB |
| Critical watermark | `GlobalSettings.criticalWatermarkBytes` | 5 GiB |
| Staging soft limit | `GlobalSettings.stagingSoftLimitBytes` | 4 GiB |
| Backfill rate | `GlobalSettings.backfillBytesPerHour` | 20 GiB per hour |
| Metric used by the guard | `Sources/PhotoVaultCore/Policies/DiskGuardPolicy.swift`, `DiskGuardPolicy.evaluate` (`input.capacity.available`) | real free space |
| Resume margin | `DiskGuardPolicy.margin` | 5 GiB |

Decisions to update: [0015](../decisions/0015-disk-guard-watermarks.md), [0017](../decisions/0017-token-bucket-lanes.md).
