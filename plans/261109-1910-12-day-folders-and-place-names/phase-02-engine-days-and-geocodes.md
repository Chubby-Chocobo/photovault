---
phase: 02
title: "Engine: every day a folder, second-locale geocodes"
status: completed
priority: P2
size: L
human_effort: 1h
dependencies: [01]
touches:
  - Sources/PhotoVaultEngine/**
  - Tests/PhotoVaultEngineTests/**
acceptance:
  - swift test --filter PhotoVaultEngineTests
---

# Phase 02: Engine

## Requirements
- Promotion at the first camera asset (`count > 0`); `ResortService` removed; layout callers drop `dayPromoted`.
- `GeocodeScheduler`: second request per cell in `PlaceNameRule.secondLocale(iso)`, saved under `local`; cells whose second locale is nil store the English answer under `local`.
- `OrganizationLookups.geocodes/place`: english + local, display places through `PlaceNameRule.display`.
- `PlaceNamer`: no language bookkeeping; rename when the computed name changes.
- `ViewPlanner`, sidecars, descriptions use the display places.

## Tests first
Update day-folder, place-name, view, recovery tests to the new paths and names; add: first camera asset of a day lands in the day folder without a move; a Japanese cell gets `ja` second request; a GB cell makes one request.
