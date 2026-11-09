---
phase: 01
title: "Core/Store/Engine: cloud import kinds"
status: pending
priority: P2
size: M
human_effort: 1-2h
dependencies: []
touches:
  - Sources/PhotoVaultCore/**
  - Sources/PhotoVaultStore/**
  - Sources/PhotoVaultEngine/**
  - Tests/PhotoVaultCoreTests/**
  - Tests/PhotoVaultStoreTests/**
  - Tests/PhotoVaultEngineTests/**
acceptance:
  - swift test --filter "Import|Source|Sidecar"
---

# Phase 01: cloud import kinds in Core, Store and Engine

## Overview
Lets the engine run imports whose adapter is not a Mac folder. Size M: small changes in several passes, plus parity tests.

## Requirements
- `SourceKind.googleDrive` / `.dropbox`, `SourceConfig.account` / `.remoteItems` and `SourceError.accessRevoked` are already added on the branch.
- Wherever the engine and store mean "an import", use `kind.isImport` instead of `== .localFolder`. Places to change:
  - the open-import scan in `ImportStage`;
  - `SourceRepository.withBookmarks`, renamed `readableImports` (local imports with a bookmark, plus every cloud import; the app filters cloud ones by Keychain);
  - `classifyFolderFailure` (a cloud source with no bookmark is still readable);
  - the sidecar `source.kind` (rawValue);
  - snapshot and activity.
- Generalize `SyncCoordinator.startFolderImport` to `startImport(source:kind:displayName:config:)`. Keep a thin `startFolderImport` wrapper only if it is still called; prefer updating callers in tests.
- Revoked access:
  - When an open import's listing or inspect raises `.accessRevoked`, the source goes `offline` with `statusReason = "signInRequired"`. It resumes like an offline folder once the adapter answers again.
  - On export, a closed import gets `.permanent(.resourceMissing)` (skipped). An open import is held, as for `.unavailable`.
- `ImportSnapshot` carries `kind`, `account` and `statusReason`, so the app can label rows and show "Cần đăng nhập lại".
- Name collisions and `.icloud` placeholders are adapter concerns, not engine ones.

## Tests (first)
- Parity: the same fake tree through a fake cloud `FolderImportSource` (kind `.dropbox`) and through `LocalFolderSource` gives identical keys, paths and dedupe counts.
- `accessRevoked`:
  - while listing, the import goes offline with the reason, and resumes when the adapter recovers;
  - on export of a closed import, the job is skipped;
  - on export of an open import, the job is held.
- `readableImports` returns local-with-bookmark plus cloud rows.
- An old `config_json` without the new fields decodes.
- The sidecar `source.kind` is `googleDrive`/`dropbox`. Photos sidecars stay byte-identical.
