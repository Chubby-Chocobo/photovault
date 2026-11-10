---
phase: 03
title: "Dropbox module and import adapter"
status: completed
priority: P2
size: L
human_effort: 2-3h
dependencies: [01]
touches:
  - Sources/PhotoVaultDropbox/**
  - Tests/PhotoVaultDropboxTests/**
  - Sources/PhotoVaultDrive/LoopbackRedirectServer.swift
  - Sources/PhotoVaultDrive/KeychainStore.swift
  - Package.swift
acceptance:
  - swift test --filter "Dropbox"
---

# Phase 03: Dropbox

## Overview
Adds a new module `PhotoVaultDropbox` (it depends on Core and Drive) with PKCE auth, a small API client and a `FolderImportSource`. Size L.

## Requirements
- `LoopbackRedirectServer` gets `init(..., port: UInt16 = 0)`; an occupied port gives a clear transient error.
- `SystemKeychainStore` gets `init(service:)`, with the current service as the default.
- `DropboxAuth`:
  - Authorization: `https://www.dropbox.com/oauth2/authorize` with `client_id`, `response_type=code`, `code_challenge` (S256), `token_access_type=offline`, `redirect_uri=http://localhost:53682/oauth2/callback`, `state`, `scope=files.metadata.read files.content.read account_info.read`.
  - Token endpoint: `https://api.dropboxapi.com/oauth2/token`.
    - Code exchange: `grant_type=authorization_code`, `code`, `client_id`, `code_verifier`, `redirect_uri`.
    - Refresh: `grant_type=refresh_token`, `refresh_token`, `client_id`.
    - `invalid_grant` becomes `.accessRevoked`.
- `DropboxClient`:
  - `get_current_account` (email);
  - `list_folder` (`path`, `recursive`, `limit`) and `list_folder/continue`;
  - `files/download` streamed to a file, with the `Dropbox-API-Arg` JSON escaping non-ASCII as `\uXXXX`.
  - Error mapping:
    - 401 `expired_access_token` → refresh once;
    - 409 `path/not_found` → `.fileMissing`;
    - 429 or 503 with `Retry-After` → wait or `.unavailable`;
    - network → `.unavailable`.
- `listFolders(path)` returns subfolders only, for the app's browser.
- `DropboxImportSource: FolderImportSource`:
  - The root path is `""` or `/x/y`.
  - Recursive listing of `.tag == file` entries.
  - `relativePath` is the path relative to the root, built from `path_display` and NFC-normalised.
  - Skip `is_downloadable == false`.
  - Download by `root + "/" + relativePath`.
  - Inspect and export work as for Drive (scratch file, SHA-256, metadata reader; MD5 and SHA-256 on export).
  - Each import has its own token, stored as `import-<sourceId>`.
- Logs never contain paths or emails.

## Tests (stub transport)
- The authorize URL; the exchange and refresh forms.
- Paging with a cursor; folders-only browsing; non-ASCII header escaping.
- Refresh on an expired token; `invalid_grant` gives `accessRevoked`; 409 not found gives `fileMissing`.
- Hashes match the bytes.
- The fixed-port loopback binds 127.0.0.1.
