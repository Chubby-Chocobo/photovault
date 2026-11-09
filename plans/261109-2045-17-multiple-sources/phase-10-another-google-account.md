---
phase: 10
title: "Another Google account as a source (deferred)"
status: pending
priority: P3
size: L
human_effort: 2-4h
dependencies: [08, 09]
touches:
  - Sources/PhotoVaultDrive/**
  - Sources/PhotoVaultEngine/**
  - PhotoVault/Views/Settings/SourcesTab.swift
  - Tests/PhotoVaultDriveTests/**
acceptance:
  - swift test --filter GoogleAccountSourceTests
---

# Phase 10: Another Google account (deferred; owner choice needed)

## Overview
This phase backs up the photos of a second Google account. Since 2025-03-31 the Google Photos Library API only reads media the app created, and `photoslibrary.readonly` is gone ([Google Photos API updates](https://developers.google.com/photos/support/updates)). That account's Google Photos library therefore **cannot** be synced continuously. Size L: a second OAuth account plus whichever adapter the owner picks.

## What the owner must choose and provide
1. **That account's Google Drive, continuous**: phase 08 runtime + `changes.list` with a start page token. It needs `drive.readonly` (restricted, see phase 09) and a sign-in for the second account.
2. **Google Takeout, one-time**: the owner downloads the Takeout archive. PhotoVault imports the extracted folder through the phase 05 import, reading Takeout's per-photo JSON (`photoTakenTime`, `geoData`) when EXIF has no date or place. No Google setup is needed; this is the smallest option.
3. **Google Photos Picker API, one-time per session**: the owner picks items in a browser session. It needs the Picker API enabled on the Google project and the `photospicker.mediaitems.readonly` scope.

## Requirements
- The owner's chosen option. Recommendation: option 2 first (it reuses the folder import entirely), then option 1 if continuous sync matters.

## Implementation Steps
1. Owner decision. 2. Tests first per option. 3. Adapter and UI entry.

## Success Criteria
- [ ] The chosen option imports a fixture set organised exactly like the local folder import.

## Risk Assessment
- Takeout JSON naming quirks (truncated names, `-edited` copies): handle them as duplicates by fingerprint. Restricted scopes for option 1.
