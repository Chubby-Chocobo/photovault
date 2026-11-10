---
phase: "02"
title: "Core: PlaceSplitPolicy (grouping)"
status: pending
priority: P2
size: M
human_effort: 1-2h
dependencies: []
touches:
  - Sources/PhotoVaultCore/Policies/PlaceSplitPolicy.swift
  - Sources/PhotoVaultCore/Policies/PlaceNamingPolicy.swift
  - Tests/PhotoVaultCoreTests/Policies/PlaceSplitPolicyTests.swift
acceptance:
  - swift test --filter PlaceSplitPolicyTests
  - swift test --filter PlaceNamingPolicyTests
---

# Phase 02: PlaceSplitPolicy

## Overview

Size M: one Core module, a new pure policy, and an additive change to `PlaceAsset`. It groups the assets of one promoted camera day by province and names each group with the existing rule. No clock, no I/O.

## Requirements

- `PlaceAsset` (`PlaceNamingPolicy.swift:4`) gains `id: String = ""` and `creationDate: Date? = nil`. Existing callers compile unchanged.
- `PlaceGroup { key: String?; name: String?; state: PlaceState /* named|unnamed */; members: [String] }`, members sorted.
- `PlaceSplitResult`: `.pending`, `.waitingGeocode([GeoCell])` or `.groups([PlaceGroup])`, with groups sorted by member count descending, then key ascending.
- `PlaceSplitPolicy.evaluate(_ input: PlaceNamingInput) -> PlaceSplitResult`:
  1. The day ended less than 6 h ago (the same test as `PlaceNamingPolicy.swift:60`): `.pending`.
  2. `live` are the assets that are not deleted. `usable` are the live assets that have a location and pass the hidden filter. `cells` are the cells of `usable`.
  3. `known` are the distinct `PlaceNamingPolicy.identity` values over the cells that have an `en` answer.
  4. `known.count ≤ 1`: delegate.
     - `r = PlaceNamingPolicy.evaluate(input)`, **unchanged**. `.waitingGeocode` passes through.
     - Otherwise there is one group `{r.placeKey, r.placeName, r.state, all live ids}`.
     - This is exactly today's result, transient states included (audit M2). A later answer for a detour cell marks the day dirty and comes back here.
  5. `known.count ≥ 2`:
     - Any cell still without `en`: `.waitingGeocode(those cells, sorted)`.
     - Then the anchors are the usable assets whose cell has an identity. Every live asset joins a group:
       - an anchor joins its own identity;
       - any other asset (no GPS, a cell without a province, hidden while hidden upload is off) joins the anchor with the smallest |Δ creationDate|, a tie going to the earlier anchor, then the smaller id;
       - a live asset with no `creationDate` (its date was removed after placement) is returned in `unassigned` and keeps its current slot. Undated assets are never on a day (audit M12).
  6. Per group `k`: `PlaceNamingPolicy.evaluate(input with assets = anchors of k)` gives named, unnamed (a box over 300 km) or waitingGeocode (second-locale answers missing for the representatives).
  7. Any group waiting: `.waitingGeocode(union of cells)`. Otherwise `.groups`.
- Deleted assets are never members; the engine keeps their slot.

## Tests first (`PlaceSplitPolicyTests`)

| # | Case | Expect |
|---|---|---|
| 1 | Day ended 5 h ago | pending |
| 2 | One province, 40 cells | one group equal to `PlaceNamingPolicy.evaluate` (table over the `PlaceNamingPolicyTests` fixtures) |
| 3 | One province with known cells, plus one uncached non-representative cell | the delegated result (named), not waiting |
| 4 | One province, box over 300 km | one group, unnamed |
| 5 | Hà Nội ×10 + Ninh Bình ×3 | two groups, HN first; names "Hà Nội", "Ninh Bình" |
| 6 | A → B → A | two groups |
| 7 | No GPS at 11:00 between A at 09:00 and B at 15:00; also at 12:00 exactly | A; A (earlier wins) |
| 8 | Sea cell inside a two-province day | joins by time; no group of its own |
| 9 | Hidden GPS photo while hidden is off | no group; joins by time |
| 10 | Deleted photo in province C | no group C, not a member |
| 11 | Two provinces known, a third cell uncached | waitingGeocode with that cell |
| 12 | B has `en` but no `local` for its representative | waitingGeocode |
| 13 | A single GPS photo in C | its own group |
| 14 | Abroad + home | country suffix on the abroad group |
| 15 | Live asset without `creationDate` in a two-province day | in `unassigned` |
| 16 | Shuffled input | identical result |

## Risks

- In country-only fallback cells the area is the country. The engine freezes splits in that mode (phase 05), so the policy needs no special case.

## Rollback

Revert. Nothing uses the policy until phase 05.
