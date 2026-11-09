---
phase: 03
title: "Settings and app"
status: completed
priority: P2
size: S
human_effort: 30m
dependencies: [02]
touches:
  - Sources/PhotoVaultCore/Models/Settings.swift
  - Sources/PhotoVaultAppSupport/SettingsForm.swift
  - PhotoVault/**
  - Tests/PhotoVaultAppSupportTests/**
acceptance:
  - xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Release -derivedDataPath build/DerivedData -allowProvisioningUpdates build
---

# Phase 03: Settings and app

## Requirements
- Remove `dayFolderThreshold` and `placeNameLanguage` from `GlobalSettings` and validation.
- Organization tab: drop the threshold row and "Sắp xếp lại"; Places tab: drop the language picker, example text shows the new names.
