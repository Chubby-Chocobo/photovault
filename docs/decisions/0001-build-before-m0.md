# 0001 Build M1–M5 before the M0 spikes

- **Status:** Accepted (owner instruction, 2026-11-09)
- **Spec refs:** §10 (M0), §8.5, §14
- **Review trigger:** after the owner runs M0-1 and M0-2 ([docs/spikes/](../spikes/README.md))

## Context

Spec §10 and §14 require the M0 spikes to run first, after which the agent stops and reports. M0 needs the owner's Photos library, Google account and NAS, which the build agent cannot use. The owner asked for the full build in this run.

## Decision

Build M1–M5 now. Each unverified `[VERIFY]` default is implemented as the spec default and recorded in `docs/decisions/` (files 0012–0021). The M0 procedures are written to `docs/spikes/` for the owner to run. A spike result that disagrees with a default changes the setting or constant named in that spike's "Changes" section.

## Consequences

- The code runs on unverified defaults. Each one is listed with its owner and its spike.
- The §8.5 stop rule (stop if Photos never releases downloaded originals) can only be applied after M0-1 is run. Until then, large backfills are unverified.
- M0 is not complete. Spec §12 "Mọi [VERIFY] có kết luận" stays open until the spikes are recorded.
