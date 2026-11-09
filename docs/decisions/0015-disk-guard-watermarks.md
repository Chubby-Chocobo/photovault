# 0015 Disk guard: watermark comparisons, hysteresis and "GB" meaning GiB

- **Status:** Pending M0 (M0-1 sets the watermarks and the free-space metric)
- **Spec refs:** FR-05, FR-31, §8.5, T14, T15
- **Review trigger:** after the owner runs M0-1 ([spike](../spikes/m0-1-icloud-export-disk.md))

## Context

Spec §8.5 sets watermarks of 15 GB (low) and 5 GB (critical) and says the chosen metric is confirmed by M0-1. The spec writes "GB" throughout, and the code uses binary units for these values.

## Decision

`DiskGuardPolicy.evaluate` (`Policies/DiskGuardPolicy.swift`):

- **Metric:** `DiskCapacity.available` (`volumeAvailableCapacity`, real free space). `availableForImportantUsage` is measured but not used by the policy.
- **Critical:** `free < criticalWatermarkBytes` (strict). It blocks every export and sets `mustCancelAll`.
- **Low, with hysteresis:** `free < lowWatermarkBytes` pauses rate-limited exports. Resume needs `free >= lowWatermarkBytes + margin`. `margin` is `5 * GlobalSettings.GiB`.
- **Units:** every watermark and rate in `GlobalSettings` is in GiB (`15 * GiB`, `5 * GiB`, `4 * GiB`, `20 * GiB` per hour). The spec's "GB" is read as GiB.
- **Staging soft limit:** a new export starts only when `staging + in-flight < 4 GiB`. Exception: with nothing staged, nothing in flight and no active export, one export always starts.
- **Too large for disk:** after two disk cancels, a file is `tooLargeForDisk` when `bytesReceivedAtCancel + freeAtStart < critical + margin`. Retry only when `free >= knownSize + margin`.
- **Power:** rate-limited exports also need AC power, no Low Power Mode and `thermal < .serious`. The policy applies these checks unconditionally. It does not read `backfillOnlyOnACPower`; the engine must pass the setting in through the system snapshot.

## Consequences

- At the critical watermark (5 GiB) every export stops, including incremental ones. The rate limit has no effect there.
- M0-1 may change the numbers (`GlobalSettings.lowWatermarkBytes`, `criticalWatermarkBytes`, `stagingSoftLimitBytes`, `backfillBytesPerHour`) or the metric. Those are the only places to change them.
- Within one `GlobalSettings` value the binary units differ from the decimal 700 GB Drive cap. See [0016](0016-daily-upload-cap-700gb.md).
