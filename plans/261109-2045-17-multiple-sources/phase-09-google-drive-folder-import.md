---
phase: 09
title: "Google Drive folder import, one-time (deferred)"
status: pending
priority: P3
size: L
human_effort: 2-4h
dependencies: [05]
touches:
  - Sources/PhotoVaultDrive/DriveFolderSource.swift
  - Sources/PhotoVaultDrive/OAuthClient.swift
  - PhotoVault/Views/Settings/SourcesTab.swift
  - Tests/PhotoVaultDriveTests/**
acceptance:
  - swift test --filter DriveFolderSourceTests
---

# Phase 09: Google Drive folder import (deferred; owner setup needed)

## Overview
This phase imports every photo and video under a Drive folder once, organised like everything else, using the phase 05 pipeline with a Drive-backed `FolderImportSource`. Size L: OAuth scope change, a new adapter and a security-sensitive surface.

## What the owner must provide
- A decision on the access model:
  - **(a)** add the restricted scope `https://www.googleapis.com/auth/drive.readonly` to the existing Google Cloud OAuth consent screen. In "Testing" status, with the owner as test user, no verification is needed, but refresh tokens expire after 7 days. Publishing needs Google's restricted-scope verification.
  - **(b)** the Google Picker to choose the folder under `drive.file`. It needs a Picker API key and a browser page served over the loopback. Whether picking a folder grants access to the files inside it is `[UNVERIFIED]`; check this first.
- Which account: the destination account, or another one (another one needs phase 08's Keychain keys).

## Requirements
- `DriveFolderSource: FolderImportSource`. `listFiles` = recursive `files.list` (`'<id>' in parents`, `trashed = false`, image/video MIME types), with `md5Checksum` and `imageMediaMetadata` (time, location, camera) taken from the metadata. `inspect` = a streamed download with hashing. `exportResource` = a streamed `alt=media` download into staging.
- Dedupe by `md5Checksum` before any download (against `resource.md5`), and by SHA-256 after the download (`x:` key).
- Shortcuts and Google Docs are skipped. Files owned by others are imported when readable.

## Implementation Steps
1. Owner decision and setup. 2. Tests with `HTTPTransport` stubs (`Sources/PhotoVaultDrive/HTTPTransport.swift`). 3. Adapter. 4. UI entry "Nhập từ Google Drive…".

## Success Criteria
- [ ] Importing a stub tree of 50 files gives the same result as the same tree imported from a local folder.

## Risk Assessment
- Restricted scope and policy (Google verification); 7-day token expiry in Testing mode; download quotas.
