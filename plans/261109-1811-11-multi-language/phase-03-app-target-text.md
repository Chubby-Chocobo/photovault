---
phase: 03
title: "App target text"
status: completed
priority: P2
size: L
human_effort: 1-2h
dependencies: [01]
touches:
  - PhotoVault/**
  - Config/PhotoVault-Info.plist
acceptance:
  - xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Debug build CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData
---

# Phase 03: App target text

## Overview
All views, AppModel notices, window titles and services use `tr(vi:en:)`. Size: L (~450 strings across ~45 files).

## Requirements
- SwiftUI: `Text(tr(...))`, `Button(tr(...))`, etc. — the `String` overloads, so SwiftUI does no catalog lookup of its own. Components taking `String` titles keep their signatures.
- Destination names and their mirrors stay literal, one form in both languages: "Camera Uploads", "Camera Uploads 2", view toggles "By device" / "By place" / "Favorites" (they name folders on Drive).
- Region names in Places use `Locale(identifier: L10n.language.rawValue)`.
- Places tab: the existing picker is labelled "Ngôn ngữ tên địa danh" / "Place-name language" with a note that changing it renames day folders on destinations.
- Language own-names "Tiếng Việt" and "English" are marked `// l10n: verbatim`.
- Info.plist `NSPhotoLibraryUsageDescription`: Vietnamese sentence then English sentence.
- Scenes: window titles via `tr`.

## Tests first
No unit-test target for the app; the guard is `UITextCoverageTests` (run locally with the disabled trait removed) plus the build.

## Implementation Steps
1. Enable the coverage test locally to list `PhotoVault/` literals (the to-do list).
2. Convert folder by folder (App, Engine, Services, Views/*).
3. Build.

## Success Criteria
- [x] Coverage test clean for `PhotoVault/`; app builds.

## Risk Assessment
Two writers in parallel must not touch the same file: split by folder.
