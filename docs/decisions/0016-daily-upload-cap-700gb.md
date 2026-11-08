# 0016 Drive daily upload cap: 700 × 10⁹ bytes, rolling 24 hours

- **Status:** Pending M0-3 (the Drive limit itself)
- **Spec refs:** FR-49 (700 GB / 24 hours), §8.14
- **Review trigger:** after M0-3 measures the real Drive limit, or when the cap is changed

## Context

FR-49 caps Drive uploads at 700 GB per rolling 24 hours. Google's per-day upload limit is the figure M0-3 has to measure; the cap must stay below it.

## Decision

- Decimal bytes: `DailyUploadCap.defaultLimit = 700 * 1_000_000_000` (`PhotoVaultDrive/DailyUploadCap.swift`). This is the cap `GoogleDriveDestination` uses (`cap: DailyUploadCap = DailyUploadCap()`).
- The window is 24 hours (`DailyUploadCap.window`). Usage is the sum of entries less than 24 hours old. `canUpload` checks `usage + bytes <= limit`.
- A second type, `RollingByteCap` in `PhotoVaultCore/Policies/TokenBucket.swift`, has the same default (`700_000_000_000`, documented as "below the 750 GB Drive limit"). Nothing in `Sources/` uses `RollingByteCap`; only `DailyUploadCap` is wired.

## Consequences

- Two constants describe the same limit. `RollingByteCap` is dead code and should be removed or merged when the engine lands.
- The cap is an in-memory count. The engine must persist `entries` across restarts (the source comment says so). Until it does, a restart resets the count.
- If M0-3 measures a lower limit, change `DailyUploadCap.defaultLimit` only.
