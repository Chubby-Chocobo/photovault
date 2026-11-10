---
phase: "03"
title: "Core: DaySlotPolicy and slot-aware layout"
status: pending
priority: P2
size: M
human_effort: 1.5-2.5h
dependencies: ["02"]
touches:
  - Sources/PhotoVaultCore/Policies/DaySlotPolicy.swift
  - Sources/PhotoVaultCore/Rules/DynamicLayout.swift
  - Tests/PhotoVaultCoreTests/Policies/DaySlotPolicyTests.swift
  - Tests/PhotoVaultCoreTests/SplitDayLayoutTests.swift
acceptance:
  - swift test --filter DaySlotPolicyTests
  - swift test --filter SplitDayLayoutTests
  - swift test --filter PhotoVaultCoreTests
---

# Phase 03: DaySlotPolicy and layout

## Overview

Size M because it changes the public `LayoutPolicy` contract, in a compatible way. The phase maps groups onto folders (slots) and teaches `DynamicLayout` the extra-folder path.

## Requirements

### Layout (`Rules/DynamicLayout.swift`)

- The requirement becomes `folderChain(for:placeName:slot:)`. An extension keeps `folderChain(for:placeName:)` passing `slot: nil`.
- A camera placement on a real day with a slot gives the last level `camera/<day>@<slot>` with display `dayFolderName(day, placeName)`. Screenshot, Saved and `unknown` ignore the slot.
- `slotLogicalPath(day:slot:)`, and `parseCameraDay(_:) -> (day, slot?)?`, which accepts slots matching `^[pr][0-9a-f]{12,}$`.

### DaySlotPolicy (`Policies/DaySlotPolicy.swift`)

Inputs:
- `DaySlot { slot: String? /* nil = main */; key: String?; name: String?; reservedNames: [String?] }`. `reservedNames` are names still on disk at some destination: the `fromValue`s of open `renameFolder` jobs for that slot's path.
- `assign(day:, groups:, slots:) -> DaySlotPlan`, where the plan holds `slotOfGroup`, `updated` (the used slots with their new key, name and state) and `assetSlots`. `slots` always contains the main slot.
- `ck(name)` is `NameSanitizer.collisionKey(DynamicLayout.dayFolderName(day, placeName: name))`.

The name index:
- **Initial content:** for every slot, the `ck` of its current name and of each reserved name, mapped to that slot.
- **Exception (audit M1):** a main slot whose name and key are both nil (never named) is left out of the initial index unless some group has a nil name.
- During the run, every assignment adds `ck(group.name)` mapped to its slot. Entries are never removed within a run, so vacated names stay reserved.

Passes. Each runs over **all** groups, in input order, before the next. A group assigned in an earlier pass is skipped.
1. **Name:** `index[ck(group.name)]` exists: assign that slot.
2. **Key:** first the index lookup again. Otherwise, if `group.key != nil` and the main slot has the same key, or a row has that key, and that slot is not yet assigned in this run: assign it.
3. **Main:** first the index lookup. Otherwise, if no group has the main slot yet: the first remaining group takes it.
4. **New:** first the index lookup. Otherwise the slug is `p + hex(sha256(key ?? ""))` at 12 digits; if that slug exists among `slots` or was assigned in this run, try 16, 20 and so on.
- `updated[slot]` takes the key, name and state of the first group assigned to that slot (the largest). Slots no group used are left out of `updated`; they are frozen.
- Slug helpers: `slug(forKey:)` and `slug(forRecoveredName:)` (`r + hex(sha256(collisionKey(displayName)))` at 12 digits, lengthened the same way by the caller).

Invariants, tested and fuzzed:
- **(a)** For every final slot name, no *other* slot's current name, reserved name or final name has the same `ck`.
- **(b)** Every group's `ck(name)` equals its slot's final `ck`.
- **(c)** The same input gives the same output.
- **(d)** A new slug never equals an existing slug.

## Tests first

`SplitDayLayoutTests`:
- With `slot: nil`, the chain is identical to today's (camera, screenshot, saved, unknown, with and without a place).
- `@slot` gives the path and display name; screenshot ignores the slot.
- `LegacyRootProbe.isLegacyLogicalPath("camera/2026-11-08@p0123456789ab") == false`.
- `ArchiveDay(string:)` rejects the suffixed form.
- `parseCameraDay` round-trips and rejects `@x` and `@p12`.

`DaySlotPolicyTests`:

| # | Slots before | Groups | Expect |
|---|---|---|---|
| 1 | main(nil, nil) | [Đà Lạt] | main ← Đà Lạt |
| 2 | main(K, "Đà Lạt") | [K "Đà Lạt"] | main, no change |
| 3 | main(K, "P. Cửa Nam") | [K "Hà Nội"] | main renamed |
| 4 | main(nil, nil) | [HN×10, NB×3] | HN→main (pass 3), NB→`p…`; HN is not moved |
| 5 | main(nil, nil) | [HN×10 named, X×3 unnamed] | X→main (bare-date match, M1 exception); HN→`p…` |
| 6 | main(HN), p1(NB) | [NB×20, HN×2] | no swap |
| 7 | main(nil, "Hà Nội"), r1(nil, "Ninh Bình") | [HN, NB] | name match; keys filled |
| 8 | main(HN), p1(NB) | [NB only] | NB→p1; main frozen |
| 9 | main(nil, nil) | [X unnamed, Y unnamed] | both → main |
| 10 | main(HN), p1(K1 "Ninh Bình") | [K2 "Ninh Bình"] | → p1 |
| 11 | main(K, "Hà Nội", reserved ["P. Cửa Nam"]) | [K "Hà Nội", K3 "P. Cửa Nam"] | K3 → main (name still on disk); invariants hold |
| 12 | main(K1 "A"), p1(K2 "B") | [K2 "C" (renamed), K4 "B"] | pass 1: K4→p1 by name; pass 2: K2's row is taken, so K2 gets a lengthened `p…` with "C"; invariants hold |
| 13 | `slug(K)` equals an existing slug of another key | | lengthened |
| 14 | fuzz: 1,000 seeded runs, 6 names (incl. nil), 4 keys (incl. nil), random reserved names | | (a)–(d) |

## Risks

- `DynamicLayout.swift` is also edited by #24 (view chains, another function). Rebase.

## Rollback

Revert. With `slot: nil` everywhere the behaviour is identical.
