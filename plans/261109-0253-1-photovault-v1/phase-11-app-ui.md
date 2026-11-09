---
phase: 11
title: "App: menu bar, onboarding, Settings, notifications"
status: completed
priority: P1
size: L
human_effort: 5-8h
dependencies: [02, 05, 06, 07, 10]
touches:
  - PhotoVault/**
  - Sources/PhotoVaultEngine/**
acceptance:
  - xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Debug build CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData
  - swift test
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 11: App (M2)

## Overview
The SwiftUI app: composition root, `MenuBarExtra` (FR-60), onboarding (FR-01), Settings (FR-05/06/07/08/70–72/104/103), activity (FR-63), notifications (FR-61), login item (FR-62), single instance (FR-54), system monitors (FR-14, NFR-02, NFR-05). Matches the phase-02 mockups. Size: L — every screen plus platform integration.

## Requirements
- `AppEnvironment` builds Store, PhotoKitSource, OAuth/Keychain, destinations, engine; instance lock first — second instance shows "PhotoVault đang chạy" and exits.
- Monitors: `NWPathMonitor` (expensive/constrained), power source + Low Power Mode + `thermalState`, sleep/wake, volume mount (`NSWorkspace.didMountNotification`), Photos change observer with 30–60 s debounce, `NSBackgroundActivityScheduler` 60 min; `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` while jobs run (NFR-02).
- Onboarding steps 1–9 in order, ending with baseline → scan → recovery → upload.
- Settings with every FR-05 row; scope change (FR-06), timezone (FR-07), account/root (FR-08), destinations (FR-70/71/72, NSOpenPanel + bookmarks, Test connection), views + device groups, place-name privacy note (FR-85), integrity "Kiểm tra ngay", "Sắp xếp lại", "Dựng lại view", retry deferred/skipped.
- Notifications via `UNUserNotificationCenter`, throttled ≤ 1 per kind × destination per 12 h (FR-61 list).
- `SMAppService.mainApp` register/unregister (FR-62).
- Logging: `os.Logger` + rotating file log 5 × 5 MB (NFR-07), "Log" menu item reveals it.
- UI strings in Vietnamese.

## Implementation Steps
1. View models tested in package tests where logic lives (formatters, ETA, notification throttle) — put that logic in `PhotoVaultEngine` (`UIState`, `NotificationPolicy`).
2. Build SwiftUI views per mockup; build the app with `xcodebuild`.

## Success Criteria
- [x] App builds; package tests green.

## Risk Assessment
- No signing identity on this machine: the app is only built unsigned here; Personal Team signing steps go to README (M0-4).

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- Settings also exposes: run reconciliation (FR-13), "Làm mới địa danh" (FR-106), "Khôi phục giúp tôi" (FR-47), add/remove destination with its own scope prompt (FR-71), root rename and account change (FR-08).
- FR-61 duration notifications use the persisted since-timestamps (`status_since`, kv).
- Unsandboxed launch without `--dev-container` shows an explanation and quits (phase 08 rule).
- File log follows the redaction policy: asset keys and job IDs only, no file names, album titles or coordinates.
