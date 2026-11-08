# 0018 Retry backoff: full jitter from 1 second to 30 minutes

- **Status:** Accepted
- **Spec refs:** NFR-04 (jitter, 1 second to 30 minutes), §8.14
- **Review trigger:** when retry behaviour is observed to cause throttling

## Context

NFR-04 requires exponential backoff with jitter from 1 second up to 30 minutes. It does not pick a jitter form.

## Decision

`Backoff` (`PhotoVaultCore/Policies/Backoff.swift`):

- `ceiling(forAttempt:) = min(30 min, 1 s × 2^attempt)`. The exponent is clamped to `0...40`.
- Delay is uniform in `0 ... ceiling` (full jitter). The random source is injected, so tests are deterministic.

Alternative not chosen: equal jitter (half the ceiling plus a random half). Full jitter spreads retries widest.

## Consequences

- A retry can fire after almost no delay. Per-destination and per-item limits (spec §8.14) still apply.
- Tests use an injected generator; production uses `SystemRandomNumberGenerator`.
