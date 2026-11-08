---
phase: 06
title: "Google Drive: OAuth, Keychain, REST, resumable upload"
status: done
priority: P1
size: L
human_effort: 5-8h
dependencies: [03]
touches:
  - Sources/PhotoVaultDrive/**
  - Tests/PhotoVaultDriveTests/**
acceptance:
  - swift test --filter PhotoVaultDriveTests
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 06: Google Drive

## Overview
OAuth (FR-02/03/08), Drive v3 REST client, resumable uploads with pre-generated IDs and checksum verification (FR-43..49), and `GoogleDriveDestination: Destination`. Size: L — security-sensitive auth and the main remote contract.

## Requirements
- `OAuthClient`: Authorization Code + PKCE (S256, 43–128 char verifier), `state` check, loopback `NWListener` on `127.0.0.1` random port, opens default browser via an injected opener, token exchange and refresh, revoke on sign-out; scopes `https://www.googleapis.com/auth/drive.file openid email`; user ID from the ID token `sub` (FR-08 account change detection).
- `KeychainStore` (generic password, service `com.annh.photovault.google`); refresh token never logged (NFR-06).
- `DriveAPI` over an injectable `HTTPTransport` (URLSession in production): `generateIds(type: files|shortcuts)`, `files.create` (metadata + appProperties, `fields=id,md5Checksum,trashed,parents`), `files.get`, `files.update` (metadata, media, addParents/removeParents for move, `trashed`), `files.list` with `appProperties has { key='pvSchema' and value='1' }` paging, `about.get storageQuota`, shortcuts (`application/vnd.google-apps.shortcut`, `shortcutDetails.targetId`).
- `ResumableUploader`: session start with the pre-generated ID, chunk size multiple of 256 KiB (default 8 MiB), `PUT Content-Range: bytes */N` status probe → 308 range, resume; session lost → `files.get` first (match → done; differs → `files.update` media; missing → new session same ID) (FR-44).
- `GoogleDriveDestination`: root check each cycle (FR-47: missing/trashed → paused, never re-created), folder creation serialized by an actor, `trashed` checks on writes, 404 handling, quota (FR-48), daily cap 700 GB/24h and write token bucket (FR-49), appProperties (`pvAssetId` with `h:` fallback, `pvResType`, `pvKind`, `pvCategory`, `pvSchema=1`, folders `pvLogical`/`pvView`), `description` "Camera: … · Lens: … · Place: …".
- Errors mapped through Core `ErrorClassifier` (401 → refresh once; repeated 429/5xx → destination-level).

## Implementation Steps
1. Tests with a stub transport: PKCE vectors (RFC 7636 appendix B), loopback callback parsing (code, state mismatch, error), token refresh and `invalid_grant`, generateIds/create/get/update request shapes, resumable flow (308 resume, lost session → files.get branches), checksum mismatch path, root trashed → paused, appProperties 124-byte rule.
2. Implement.

## Success Criteria
- [ ] Drive tests green; no network in tests.
- [ ] No token value in any log statement (grep check in review).

## Risk Assessment
- [VERIFY M0-3] `drive.file` with shortcuts, generateIds per type, session lifetime, appProperties limit, list after reinstall: defaults per spec, decisions recorded; views auto-disable if shortcut creation returns 403 (FR-103).

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- Two-step creates per the Phase 03 `Destination` contract: IDs come from `reserveIds`, the engine persists them, then create/session start. `onSession` persists `session_ref` + `session_md5` before the first byte.
- Loopback: `NWParameters.requiredLocalEndpoint = 127.0.0.1:0` (test asserts the bound host), one request on the exact path, constant-time `state` compare, static HTML that echoes nothing, listener cancelled after the first callback or 5 minutes.
- ID token: check `aud == clientID`, `iss` in Google issuers, `exp`.
- Sign-out deletes the Keychain item unconditionally, then best-effort revoke.
- Keychain: data-protection keychain (`kSecUseDataProtectionKeychain`), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable; `errSecInteractionNotAllowed` → transient, `errSecItemNotFound` → `reauthRequired`; never start OAuth automatically.
- Redaction: `HTTPTransport` logs method, host, path template and status only; tokens, code, verifier, client secret, ID token and session URIs never logged; test with sentinel strings through an injected `LogSink`.
- `pvRoot=1` on the root; `findRoots()` for FR-01 step 3.
- `alreadyExists` (409 or duplicate ID) → `files.get` and compare `parents`/`shortcutDetails.targetId`/`md5Checksum`; never assume success.
- `DriveQuery` builder escapes `\\` and `'` in every literal; no hand-built `q`.
- Archive timezone stored on the root's `appProperties` (`pvArchiveTZ`) for recovery.
- `untrash` ("Khôi phục giúp tôi") and `renameRoot` (FR-08).
- Runs `DestinationConformanceSuite` over the stub transport.
