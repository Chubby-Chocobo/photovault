---
phase: 1
title: "Reset on next launch"
status: in-progress
priority: P2
size: M
human_effort: 1-2h
dependencies: []
touches:
  - Sources/PhotoVaultEngine/FactoryReset.swift
  - PhotoVault/Engine/AppEnvironment.swift
  - PhotoVault/App/AppModel+FactoryReset.swift
  - PhotoVault/Views/Settings/AdvancedTab.swift
  - Tests/PhotoVaultEngineTests/FactoryResetTests.swift
  - README.md
  - docs/**
acceptance:
  - swift test --filter FactoryReset
---

# Phase 1: Reset on next launch

## Implementation Steps
1. Engine `FactoryReset`: `request(layout)` writes the marker; `isRequested`; `applyIfRequested(layout)` deletes every item in the data folder except the lock file and `drive-daily-cap.json`, marker last.
2. `AppEnvironment.make`: when a reset is requested, retry the lock while the old process exits; apply the reset after the lock, then prepare the folders again.
3. App: `factoryReset()` pauses sync, signs out of Google, writes the marker, relaunches (`createsNewApplicationInstance`) and terminates.
4. Advanced tab: destructive row and confirmation text.
5. Tests: kept files, marker removed last, nothing happens without a marker, a partial wipe keeps the marker.

## Success Criteria
- [ ] A reset ends in onboarding with an empty database and the language kept.

## Risk Assessment
- Relaunch can fail in the sandbox: the marker stays, the reset completes when the owner opens the app.
