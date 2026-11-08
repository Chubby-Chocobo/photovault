---
phase: 01
title: "Scaffold: SPM package, Xcode app project, CI, config"
status: pending
priority: P1
size: M
human_effort: 2-3h
dependencies: []
touches:
  - Package.swift
  - Package.resolved
  - Sources/
  - Tests/
  - PhotoVault/
  - PhotoVault.xcodeproj/
  - Config/
  - .github/workflows/ci.yml
  - .gitignore
acceptance:
  - swift build
  - swift test
  - xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Debug build CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 01: Scaffold

## Overview
Creates the package with every target from the module graph, a thin Xcode app target that depends on it, build configuration (bundle ID `com.annh.photovault`, sandbox entitlements, Info.plist keys, secrets template) and CI. Size: M — many files, no logic.

## Requirements
- Swift tools 6.1, Swift 6 language mode, macOS 14 deployment target.
- One external dependency: GRDB.swift `from: "7.12.0"` (spec §6).
- Targets: `PhotoVaultCore` (with `Resources/device-names.json`), `PhotoVaultStore`, `PhotoVaultPhotos`, `PhotoVaultDrive`, `PhotoVaultLocal`, `PhotoVaultEngine`, `PhotoVaultTestSupport`; test targets `<Target>Tests` for each library.
- Xcode project `PhotoVault.xcodeproj`, app target `PhotoVault`, scheme `PhotoVault` (shared), local package reference to `.`.
- Info.plist: `LSUIElement = YES`, `NSPhotoLibraryUsageDescription`, `CFBundleShortVersionString = $(MARKETING_VERSION)`, `PVGoogleClientID = $(GOOGLE_CLIENT_ID)`, `PVGoogleClientSecret = $(GOOGLE_CLIENT_SECRET)`.
- Entitlements (spec §6): `com.apple.security.app-sandbox`, `com.apple.security.personal-information.photos-library`, `com.apple.security.network.client`, `com.apple.security.network.server`, `com.apple.security.files.user-selected.read-write`, `com.apple.security.files.bookmarks.app-scope`. Hardened Runtime on.
- `Config/Base.xcconfig` includes `Version.xcconfig`, optional `Secrets.xcconfig` (`#include?`) and optional `Local.xcconfig` (DEVELOPMENT_TEAM for Personal Team signing). `Config/Secrets.xcconfig.example` and `Config/Local.xcconfig.example` committed; real ones gitignored.
- CI (`.github/workflows/ci.yml`, macOS runner): `swift build`, `swift test`, `xcodebuild … CODE_SIGNING_ALLOWED=NO`.

## Implementation Steps
1. Write `Package.swift` with all targets and test targets; each library gets one real source file (module namespace and version constant) so it compiles.
2. Write the Xcode project by hand with file-system synchronized groups for `PhotoVault/`, a local Swift package reference, product dependencies on every library, build settings from `Config/*.xcconfig`.
3. Minimal app entry (`PhotoVaultApp.swift`) with a `MenuBarExtra` so the target builds; phase 11 replaces it.
4. CI workflow; `.gitignore` additions (`Config/Local.xcconfig`, `build/`).
5. Verify the three acceptance commands.

## Success Criteria
- [ ] All three acceptance commands pass locally.
- [ ] `xcodebuild -list` shows scheme `PhotoVault`.

## Risk Assessment
- Hand-written pbxproj may be rejected by Xcode: validate with `xcodebuild -list` early; fallback is to regenerate it with the same structure.
- GitHub macOS runners may lag Xcode 26: CI pins `macos-15` with the newest stable Xcode >= 16.3 (see Audit additions).

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- `Package.swift` uses swift-tools-version 6.1 (GRDB 7.12.0 requires 6.1).
- CI: `runs-on: macos-15`, select the newest installed Xcode >= 16.3 with `maxim-lobanov/setup-xcode@v1` (`latest-stable`), `concurrency` cancel-in-progress, path filters; the `xcodebuild` job runs only when `PhotoVault/**`, `PhotoVault.xcodeproj/**`, `Config/**` or `Package.*` change. Private repo: macOS minutes are billed at 10x, so keep one job per push.
- Tests that need HEIC encoding skip with a reason when `CGImageDestinationFinalize` fails.
