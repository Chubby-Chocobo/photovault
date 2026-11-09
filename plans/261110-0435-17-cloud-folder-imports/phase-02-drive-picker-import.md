---
phase: 02
title: "Google Drive picker import adapter"
status: pending
priority: P2
size: L
human_effort: 2-3h
dependencies: [01]
touches:
  - Sources/PhotoVaultDrive/**
  - Tests/PhotoVaultDriveTests/**
acceptance:
  - swift test --filter "DrivePicker|DriveImport"
---

# Phase 02: Google Drive picker import

## Overview
Adds the OAuth Picker flow and a `FolderImportSource` over Drive v3. It does not touch `LoopbackRedirectServer` or `KeychainStore` (phase 03 owns them). Size L: a new auth flow, recursive listing and streamed downloads.

## Requirements
- `GooglePickerFlow`:
  - The authorization URL has these parameters:
    - `client_id`, `redirect_uri` = loopback, `response_type=code`, `access_type=offline`;
    - `prompt=select_account consent`, `trigger_onepick=true`, `allow_multiple=true`, `allow_folder_selection=true`;
    - scope `https://www.googleapis.com/auth/drive.file` only;
    - PKCE and state.
  - `LoopbackRedirectServer` and `LoopbackRequestParser` must also hand back `picked_file_ids`. Check whether the parser exposes extra query items. If it does not, the parser is phase 02's to extend (it is not owned by 03). Coordinate only through this file list.
  - Exchange the code, then call `about.get` (`user(emailAddress)`).
  - Result: `{pickedIds, refreshToken, accessToken, expiresAt, email?}`. Tokens are redacted in `description`.
- An authorizer per import:
  - It reads the refresh token from a `KeychainStore` under the account `import-<sourceId>` (for example, a `GoogleAuthSession` initialised with an account key, or a small `DriveImportAuth` actor).
  - It refreshes on a 401.
  - `invalid_grant` becomes `SourceError.accessRevoked`.
- `DriveImportSource: FolderImportSource`:
  - `probe()`: `files.get` of the first picked id. A network failure becomes `.unavailable`; a revoked grant becomes `.accessRevoked`.
  - `listFiles()`, starting from the picked ids:
    - A picked file goes at the root under its name.
    - A picked folder lists `'<id>' in parents and trashed=false` recursively, with paging, under `<folder name>/…`.
    - Skip `application/vnd.google-apps.*` (Docs, folders handled, shortcuts) and anything whose `appProperties` has a `pv…` key (PhotoVault's own uploads and folders).
    - Duplicate names in one directory: sort by id, and give the second and later ones `stem (2).ext` and so on.
    - Keep a `relativePath → fileId` map; re-list lazily when a lookup misses after a relaunch.
    - `uti` comes from the extension via `UTType`, falling back to the mimeType.
  - `inspect`: stream `alt=media` to a scratch file in an injected directory, compute SHA-256, read metadata with the injected `FileMetadataReading`, then delete the scratch file.
  - `exportResource`: stream to `destination` and compute MD5 and SHA-256 (CryptoKit / Insecure.MD5).
  - Both honour `ExportControl` cancellation.
  - Error mapping:
    - 404 → `.fileMissing`;
    - 403 rate limit and 429 → retry or backoff, or `.unavailable`;
    - other 4xx → `.readFailed(code)`;
    - network → `.unavailable`.
- Logs never contain names, ids or emails.

## Tests (stub `HTTPTransport`)
- URL parameters; parsing `picked_file_ids`; a cancelled consent (`error=access_denied`).
- A tree listing with paging, skips (Docs, shortcuts, `pv` items, trashed) and name collisions.
- A folder that returns no children gives no entries and no error.
- Inspect and export hashes match the bytes.
- Refresh on 401; `invalid_grant` gives `accessRevoked`; 404 gives `fileMissing`; re-listing after a relaunch finds the id.
