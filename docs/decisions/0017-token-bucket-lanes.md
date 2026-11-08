# 0017 Token bucket: upload and metadata lanes; export rate capacity equals the hourly rate

- **Status:** Pending M0-3 (the Drive write rate); export rate pending M0-1
- **Spec refs:** FR-49 (token bucket for every Drive write), §8.5 (20 GB per hour for backfill and re-export), NFR-03
- **Review trigger:** after M0-3 sets the Drive refill rate, and after M0-1 confirms the backfill rate

## Context

FR-49 needs one token bucket for every Drive write. Metadata and view writes must not starve uploads. Spec §8.5 sets a separate backfill rate of 20 GB per hour for exports.

## Decision

`TokenBucket` (`PhotoVaultCore/Policies/TokenBucket.swift`) has two lanes:

- `upload` may use the whole bucket. A request larger than the bucket is admitted when the bucket is full, and the excess becomes debt that later refills repay.
- `metadata` may use only the part above `metadataReserve`. The reserve is `capacity × metadataReserveFraction`, with a default fraction of `0.5`. Uploads therefore win under pressure.

For exports, `ResourceGuard.currentBucket` builds `TokenBucket(capacity: rate, refillPerHour: rate)` with `rate = GlobalSettings.backfillBytesPerHour` (20 GiB). The capacity equals one hour of refill, so a full bucket lets one hour's worth of export start at once.

No Drive refill rate is set. The Drive bucket is not constructed anywhere in the code yet.

## Consequences

- Burst at start: up to 20 GiB can export at once after an idle period. M0-1 may show this is too much.
- Metadata writes (shortcuts, folder updates) get at most half the bucket. That is the intent: uploads win.
- The Drive refill rate stays unset until M0-3 gives a sustained write rate.
