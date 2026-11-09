---
phase: 01
title: "Core layout and place-name rule"
status: completed
priority: P2
size: M
human_effort: 30m
dependencies: []
touches:
  - Sources/PhotoVaultCore/Rules/DynamicLayout.swift
  - Sources/PhotoVaultCore/Policies/PlaceNameRule.swift
  - Sources/PhotoVaultCore/Policies/PlaceNamingPolicy.swift
  - Tests/PhotoVaultCoreTests/**
acceptance:
  - swift test --filter PhotoVaultCoreTests
---

# Phase 01: Core layout and place-name rule

## Overview
Pure rules: the folder chains and how a place is named. Size: M.

## Requirements
- `LayoutPolicy.folderChain(for:placeName:)` (no `dayPromoted`): camera day → `camera/<day>` named `dayFolderName`; screenshot/saved → `<branch>`, `<branch>/<day>` named `YYYY-MM-DD`; unknown unchanged.
- `viewFolderChain`: last level is the day (`…/<day>` named `YYYY-MM-DD`) for all three views.
- `PlaceNameRule`: `secondLocale(country:) -> String?` (VN → vi; else primary language, nil when English); `display(english:local:) -> GeoPlace` (country English; locality/area per rule; parentheses when different after case/diacritic folding).
- `PlaceNamingPolicy`: takes english + local maps; waits for `local` only when `secondLocale` is non-nil; names via the rule.

## Tests first
Layout chains for each category and view; rule cases: VN (Đà Lạt), JP (Kyoto (京都市)), GB (London, no parentheses), FR (Paris, same name), CN script, missing local answer → English only.
