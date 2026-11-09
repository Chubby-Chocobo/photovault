---
phase: 1
title: "Activity events"
status: completed
priority: P2
size: M
human_effort: 1-2h
dependencies: []
touches:
  - Sources/PhotoVaultCore/**
  - Sources/PhotoVaultStore/DestinationRepository.swift
  - Sources/PhotoVaultEngine/MoveWorker.swift
  - Sources/PhotoVaultEngine/ActivityLog.swift
  - Sources/PhotoVaultEngine/SyncCoordinator+Cycle.swift
  - Sources/PhotoVaultEngine/EngineSnapshot.swift
  - Sources/PhotoVaultAppSupport/ActivityPresentation.swift
  - Sources/PhotoVaultAppSupport/StatusText.swift
  - PhotoVault/Views/Activity/ActivityView.swift
  - Tests/**
acceptance:
  - swift test --filter "Activity|MoveWorker|Milestone|StatusText"
---

# Phase 1: Activity events

## Implementation Steps
1. Core: `ActivityKind.milestone`; `DestinationStatusText` (labels and reasons) moved from AppSupport `StatusText`, which delegates.
2. Store: `setStatus` records `statusChanged` "<old> → <new>" when the status changes.
3. Engine: `MoveWorker` collects renames (visible folders only) and moves (by target folder) per destination pass and records them through `ActivityLog` (≤ 5 lines, else a summary).
4. Engine: cycle end records "uploaded N files" per destination and the one-time backfill-finished row (KV flag per destination, reset when backfill work reappears; only after a drained cycle).
5. App: filter chip "Tiến độ", tint, labels.
6. Tests for each event and the summaries.

## Success Criteria
- [x] Each event kind recorded with tests; no file names in any message.
