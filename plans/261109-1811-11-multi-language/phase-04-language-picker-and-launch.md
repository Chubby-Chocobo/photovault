---
phase: 04
title: "Language picker and live switch"
status: pending
priority: P2
size: M
human_effort: 1h
dependencies: [01, 03]
touches:
  - PhotoVault/PhotoVaultApp.swift
  - PhotoVault/App/AppModel.swift
  - PhotoVault/App/AppModel+Settings.swift
  - PhotoVault/Views/Settings/GeneralTab.swift
  - PhotoVault/Views/Onboarding/**
acceptance:
  - xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Release -derivedDataPath build/DerivedData -allowProvisioningUpdates build
---

# Phase 04: Language picker and live switch

## Overview
Settings → General → Interface language (System / Tiếng Việt / English), also on the first onboarding page; switching re-renders everything at once. Size: M.

## Requirements
- `AppModel.interfaceLanguage: InterfaceLanguageChoice` (observable), loaded from UserDefaults `PVInterfaceLanguage` in `AppModel.init` (before any view renders), default `.vi`; setting it saves, sets `L10n.current = choice.resolved(preferredLanguages: Locale.preferredLanguages)`.
- Every scene root (menu content, menu label, onboarding, activity, settings) is keyed on the resolved language (`.id(...)`) so cached text re-renders.
- Picker note: "Hoạt động đã ghi giữ nguyên ngôn ngữ lúc ghi." / "Activity already recorded keeps its language."

## Tests first
`InterfaceLanguageChoice.resolved` is covered in phase 01. Manual on the signed build: switch both ways; check menu, each Settings tab, onboarding, activity window, a notification; screenshot English screens.

## Implementation Steps
1. Model property, persistence, launch application.
2. Picker in General and onboarding step 1.
3. Scene re-keying; manual check.

## Success Criteria
- [ ] Switching updates open windows and the menu immediately and survives relaunch.
