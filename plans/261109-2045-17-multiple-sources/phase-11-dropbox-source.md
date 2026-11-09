---
phase: 11
title: "Dropbox as a continuous source (deferred)"
status: pending
priority: P3
size: L
human_effort: 2-4h
dependencies: [08]
touches:
  - Sources/PhotoVaultDropbox/**
  - Package.swift
  - PhotoVault/Views/Settings/SourcesTab.swift
  - Tests/PhotoVaultDropboxTests/**
acceptance:
  - swift test --filter DropboxSourceTests
---

# Phase 11: Dropbox (deferred; owner registers an app)

## Overview
This phase adds a long-lived Dropbox source (a whole account or one folder) on the phase 08 runtime. Size L: a new module, OAuth for a new provider and a change feed.

## What the owner must provide
- A Dropbox app at the Dropbox App Console with scoped access and the permissions `files.metadata.read`, `files.content.read` and `account_info.read`; the choice of access type (App folder or Full Dropbox); the **App key** (PKCE public client, no secret shipped); and the redirect URI `http://127.0.0.1:<port>/oauth` (loopback, as for Google: decision 0003). Development status is enough for a single owner.

## Requirements
- A `PhotoVaultDropbox` module (Core-only dependency), with OAuth PKCE and `token_access_type=offline` reusing `PKCE.swift` and `LoopbackRedirectServer.swift` patterns.
- `files/list_folder` (recursive) + `list_folder/continue` cursor + `list_folder/longpoll`; `content_hash` for dedupe before download; `files/download` streamed; `media_info` for time and location where present.

## Implementation Steps
1. Owner setup. 2. Tests with transport stubs. 3. Module, adapter, UI "Thêm Dropbox…".

## Success Criteria
- [ ] Stubbed insert, update and delete over 3 cycles match the phase 08 expectations.

## Risk Assessment
- Dropbox's `content_hash` algorithm (SHA-256 over 4 MiB block hashes) differs from the file SHA-256, so it is stored separately. Rate limits per app.
