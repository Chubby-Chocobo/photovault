---
title: "One-time import from a Google Drive folder or a Dropbox folder"
description: "Cloud one-time imports on the existing import pipeline: Google desktop Picker (any account, drive.file) and Dropbox (PKCE, in-app folder browser)"
status: in-progress
priority: P2
size: L
human_effort: 6-10h
issue: 17
branch: feat/17-cloud-folder-imports
tags: [sources, import, drive, dropbox, ui]
created: 2026-11-10
sources:
  - "tracker: github:Chubby-Chocobo/photovault#17"
  - "context: file:plans/261109-2045-17-multiple-sources/reports/research-picker-dropbox-and-roadmap-sources.md"
authoritative: "tracker: github:Chubby-Chocobo/photovault#17"
---

# Plan: one-time import from Google Drive and Dropbox (issue #17, round 2)

The owner asked on 2026-11-10 to choose a folder on Google Drive or Dropbox as a one-time import. Round 1 (v0.2.0) shipped the source model and the import from a folder on this Mac. This round adds two adapters to that pipeline. Each adapter is a new `FolderImportSource`:

- `ImportStage` is unchanged: list, group, inspect (hash and metadata), dedupe, ingest.
- `ExportWorker` is unchanged and reads through `SourceRegistry`.
- Placement, sidecars and views are unchanged.

## Outcome

Settings › Nguồn › **Nhập ảnh…** gets three items: Từ thư mục trên Mac…, **Từ Google Drive…** and **Từ Dropbox…**.

**Google Drive**
- A short sheet explains what to pick. The system browser then opens Google's desktop Picker flow (`trigger_onepick`) on the account the owner chooses.
- The owner picks photos, videos and/or folders.
- The import lists the picked files, plus whatever Google lets the app read inside the picked folders, and runs like a folder import.
- The import row and the menu bar card show "Google Drive · <email>".

**Dropbox**
- The owner signs in once (PKCE in the browser), then chooses a folder in an in-app browser, or the whole Dropbox.
- The import runs like a folder import, and the row shows "Dropbox · <email>".

## Phases

| # | Phase | Status | Size | Depends | Owner of files |
|---|---|---|---|---|---|
| 01 | [Core/Store/Engine: cloud import kinds](phase-01-core-cloud-import-kinds.md) | completed | M | — | Core, Store, Engine, their tests |
| 02 | [Google Drive picker import adapter](phase-02-drive-picker-import.md) | completed | L | 01 | Sources/PhotoVaultDrive (except LoopbackRedirectServer), Drive tests |
| 03 | [Dropbox module and import adapter](phase-03-dropbox-import.md) | completed | L | 01 | Sources/PhotoVaultDropbox, LoopbackRedirectServer, KeychainStore, Package.swift, Dropbox tests |
| 04 | [App: entries, auth flows, Dropbox browser, registration](phase-04-app-cloud-imports.md) | completed | M | 02, 03 | PhotoVault/**, Config/**, Xcode project |
| 05 | [Docs, decision 0026, privacy page](phase-05-docs.md) | completed | S | 04 | docs/**, README.md, site/** |

Phases 02 and 03 run in parallel. Their file sets do not overlap.

## Acceptance criteria

1. The same tree of files gives the same assets, keys (`x:<sha256>`), destination paths and dedupe counts, whether it is imported from a Mac folder, from a stubbed Drive pick or from a stubbed Dropbox folder.
2. Drive:
   - Picked files are imported.
   - Children of picked folders are imported when Google returns them.
   - Google Docs, shortcuts, trashed items and anything PhotoVault itself uploaded (an `appProperties` key starting `pv`) are skipped.
   - Duplicate names in one Drive folder get distinct relative paths.
3. Dropbox:
   - A folder or the whole account is listed recursively with cursor paging.
   - Downloads stream to disk.
   - The `Dropbox-API-Arg` header is ASCII-safe.
   - An expired token refreshes once; a revoked one is reported.
4. Offline and revoked access:
   - A network failure holds an open import (`offline`). A finished import waits, as for a disk that is away.
   - A revoked grant on an open import shows "cần đăng nhập lại" and holds. On a closed import the exports wait hourly, with no error, and the finished row shows "Đăng nhập lại".
   - A rate limit or 5xx is `SourceError.busy`: the item stays pending and the job pauses for a short cooldown.
5. Tokens:
   - Each cloud import keeps its own refresh token in the Keychain (`import-<sourceId>`) and is re-registered at launch when that token exists.
   - Factory reset deletes these tokens and the Dropbox account token.
6. Privacy: logs and activity never carry file names, paths, folder ids or emails. The email and folder name appear only in Settings, the menu card and the notification.
7. Builds and tests:
   - `swift test` passes.
   - The signed Release `xcodebuild` passes.
   - Without a Dropbox App key, the Dropbox item is disabled with a hint and nothing crashes.

## Manual E2E (owner, needs setup)

- **Google:**
  1. Enable the **Google Picker API** in the existing Cloud project.
  2. Import a folder and a few picked photos from another Google account.
  3. Check whether picking only the folder gave access to its children. This settles the open question below.
- **Dropbox:**
  1. Create an app with Scoped access and the **Full Dropbox** access type.
  2. Grant the permissions `files.metadata.read`, `files.content.read` and `account_info.read`.
  3. Add the redirect `http://localhost:53682/oauth2/callback`.
  4. Put the App key in `Config/Secrets.xcconfig` as `DROPBOX_APP_KEY`.
  5. Import `/Camera Uploads`.

## Decisions

### Google: desktop Picker flow, `drive.file` only, one grant per import
- Chosen: Google's desktop Picker flow, using the existing Desktop OAuth client.
  - Parameters: `trigger_onepick=true`, `allow_multiple=true`, `allow_folder_selection=true`, `prompt=select_account consent`, scope `drive.file` only.
  - Redirect: loopback `127.0.0.1` with a random port, as for sign-in.
  - Each import keeps the refresh token of its own pick. The account can differ from the destination account.
  - The email comes from `about.get` and is used for display only.
- Alternatives:
  - `drive.readonly`: rejected by the owner, and a restricted scope.
  - A web Picker page hosted by us: needs an API key and a bridge page.
  - WKWebView: Google blocks OAuth in embedded views.
- Why: owner decision (Picker, any account). The flow needs no API key, only the Picker API enabled.
- Review later: yes. Whether a loopback redirect works with `trigger_onepick` is unverified, so the owner's E2E settles it.

### Picked folders: import what Google lets the app read, and say so
- Chosen: list the children of each picked folder recursively under `drive.file`. Under that scope, Google may return nothing for a picked folder. In that case the import finishes with what was readable. The pre-pick sheet tells the owner to open the folder and select the photos inside (⌘A). An import that found 0 files says the same.
- Alternatives: refuse folder picks; ask for `drive.readonly`.
- Why: the docs do not say whether a folder grant reaches its children. Forum reports say no. The design works either way.
- Review later: yes, after the owner's E2E.

### Dropbox: Full Dropbox, PKCE, fixed loopback port, in-app folder browser
- Chosen:
  - Auth:
    - Scoped app with Full Dropbox access.
    - PKCE public client, so no app secret is shipped.
    - `token_access_type=offline`.
    - Redirect `http://localhost:53682/oauth2/callback`. Dropbox needs an exact registered URI, so the port is fixed; the listener is bound to 127.0.0.1.
  - Account: the Dropbox account token is kept for browsing (`dropbox-account`). Each import gets its own copy (`import-<sourceId>`), so signing out or switching account does not break finished imports.
  - Folder choice: the browser is a SwiftUI sheet over `list_folder`, folders only.
  - Code: a new module `PhotoVaultDropbox`, which depends on Core and on Drive for `HTTPTransport`, `PKCE`, `LoopbackRedirectServer`, `KeychainStore` and form encoding.
- Alternatives:
  - The Dropbox Chooser (web JS): needs a hosted page.
  - App-folder access: cannot reach `/Camera Uploads`.
  - Moving the shared OAuth pieces into a new module: more churn for no behaviour.
- Why: smallest path that reaches Camera Uploads with no secret in the binary.
- Review later: yes. Revisit the module split when OneDrive arrives.

### Cloud imports reuse `folder-<uuid>` ids; the kind lives on the source row
- Chosen: `SourceKind` gains `googleDrive` and `dropbox`. Ids stay `folder-<uuid>`. `SourceConfig` gains optional fields:
  - `account` (display email);
  - `remoteItems` (Drive picked ids, or one Dropbox root path; `""` means the whole account).

  Old rows decode unchanged, so there is no migration.
- Alternatives: new id prefixes; a migration `v6`.
- Why: an import is a folder-shaped job whatever the provider. `ImportLocator`, `x:` keys and recovery stay as they are.
- Review later: no.

### Read twice, as for Mac folders
- Chosen: inspect downloads each file to a scratch file, hashes it and reads its metadata, then deletes the scratch file. Export downloads the file again into staging.
- Alternatives:
  - Adopt the scratch copy as staging.
  - Dedupe Drive files by `md5Checksum` before downloading.
- Why: keeps `ExportWorker`, the disk guard and crash recovery identical. The known cost is twice the download traffic.
- Review later: yes, if large video imports make it hurt.

### A revoked grant
- Chosen: adapters throw `SourceError.accessRevoked` on `invalid_grant`, `invalid_client` or a 401 after a refresh.
  - On an open import, the import stage sets the source to `offline` with `statusReason = "signInRequired"`. The app shows "Cần đăng nhập lại" for that import; the action reuses the start flow.
  - On a closed import (revoked, or no token at launch), the exports wait hourly, record no error and do not count as a failing sync. The row keeps `statusReason = "signInRequired"` and the finished row in Settings shows "Đăng nhập lại". A file gone while the source answers is still skipped.
  - Signing in again must be the same account; another account is refused with a notice and changes nothing. For Google the new pick is merged with the old one.
- Alternatives: skip a closed import's jobs (the first version; reversed after review because it lost files a new sign-in would save).
- Why: waiting cannot fix a revoked grant, so the open job says so; a closed import's files stay wanted for destinations added later.
- Review later: yes.

### Throttling, stable paths and the disk
- Chosen: a rate limit or 5xx is `SourceError.busy` (item stays pending, job not offline, 30 s cooldown; exports retry without an attempt). Each import saves `relativePath → remote id` in `remote-ids.json` before listing returns; reads resolve through it and a miss runs one shared listing that only adds. Dropbox reads by id. A cloud download to scratch space waits when it would eat the critical disk reserve. One delegate-based streamer serves both providers.
- Why: all found in review as ways to lose or mislabel a file.
- Review later: no.
