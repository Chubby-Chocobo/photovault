---
phase: 02
title: "AppSupport and Engine text"
status: completed
priority: P2
size: L
human_effort: 1-2h
dependencies: [01]
touches:
  - Sources/PhotoVaultAppSupport/**
  - Sources/PhotoVaultEngine/**
  - Tests/PhotoVaultAppSupportTests/**
acceptance:
  - swift test --filter "PhotoVaultAppSupportTests|PhotoVaultEngineTests"
---

# Phase 02: AppSupport and Engine text

## Overview
Every string AppSupport builds for the UI and every Engine activity message becomes `tr(vi: <today's text>, en: <English>)`. Size: L (~200 strings).

## Requirements
- Vietnamese side copied verbatim (same characters, punctuation, spacing).
- English: short, plain, consistent terms (destination, backup, staging, sync, Drive, NAS, asset, day folder). Counts use `L10n.plural` with the raw `Int`, formatted number interpolated separately.
- Destination names stay literal and are not wrapped: `OnboardingFlow` root name "Camera Uploads".
- `RelativeTimeText` and `ProgressText` phrases localized; `NotificationContent` and `ErrorText` all branches.
- Engine: only activity messages (`message:` / `record(...)`), no other strings.

## Tests first
- Existing Vietnamese tests unchanged (default `vi`).
- `EnglishTextTests`: one or more English expectations per file (status, error, onboarding flow, overall status, progress, relative time, notifications, integrity notice, settings form, rules editor, activity presentation), each under `L10n.$override.withValue(.en)`.
- `DestinationNameTests`: `OnboardingFlow` default root name identical under vi and en.

## Implementation Steps
1. English tests; red.
2. Convert file by file; keep Vietnamese side verbatim.
3. Run AppSupport + Engine tests.

## Success Criteria
- [x] All AppSupport/Engine tests pass; English tests pass; coverage test (run locally) clean for these modules.

## Risk Assessment
Engine messages are built inside database closures; they read `L10n.current` (not the task-local), which is correct at runtime. No English Engine test (would need the global); the Vietnamese side is covered by existing Engine tests where they exist.
