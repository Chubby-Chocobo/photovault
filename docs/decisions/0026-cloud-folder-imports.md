# 0026 One-time import from a Google Drive folder or a Dropbox folder

- **Status:** Accepted
- **Spec refs:** §2, §9, §15 (amended); new FR-119 to FR-123 (§4.13); FR-110 to FR-116 apply unchanged
- **Review trigger:** the owner's end-to-end run shows that the Picker loopback or the picked-folder listing does not work as described below, Google or Dropbox changes a scope or redirect rule, a large import makes the double download hurt, or a continuous Dropbox or Google source is requested

## Context

Decision 0024 shipped a one-time import from a folder on this Mac. On 2026-11-10 (issue #17) the owner asked for the same import from a folder on Google Drive and from a folder on Dropbox. Both are one-time jobs: they copy photos into the same layout, names, sidecars and views as Photos assets. The source is a cloud folder instead of a security-scoped bookmark.

The owner chose a Google account per import through Google's Picker, not a fixed account, and asked for the narrowest Drive scope. Dropbox has no picker that works from a Mac app without a hosted page, so the app shows its own folder browser.

## Decision

- **Adapters.** Each cloud import is a `FolderImportSource`: `DriveImportSource` (in `PhotoVaultDrive`) and `DropboxImportSource` (in the new module `PhotoVaultDropbox`). `ImportStage`, `ExportWorker`, placement, sidecars and views do not change. `SourceKind` gains `googleDrive` and `dropbox`; the kind appears in the sidecar `source.kind` ([sidecar schema](../sidecar-schema.md#source)).
- **Module.** `PhotoVaultDropbox` depends on `PhotoVaultCore` and `PhotoVaultDrive`, and reuses `HTTPTransport`, `PKCE`, `LoopbackRedirectServer`, `KeychainStore` and form encoding from Drive. The shared pieces stay in Drive until OneDrive needs them.

### Google Drive: Picker flow, `drive.file` only, one grant per import

- **Chosen:** Google's desktop Picker flow on the existing Desktop OAuth client, with no API key.
  - Authorization parameters: `trigger_onepick=true`, `allow_multiple=true`, `allow_folder_selection=true`, `prompt=select_account consent`, scope `https://www.googleapis.com/auth/drive.file` only.
  - Redirect: loopback `127.0.0.1` on a random port, as for sign-in.
  - Each import keeps the refresh token of its own pick. The Google account can differ from the backup account.
  - The email comes from `about.get` and is shown only in Settings, the menu card and the notification.
- **Unverified:** whether a loopback redirect works with `trigger_onepick`. Google documents the Picker for web and mobile apps; the desktop flow with `trigger_onepick` is not documented. The owner's E2E run settles it. If it fails, the fallback is a page hosted by us (needs an API key), not an embedded web view, which Google blocks for OAuth.
- **Alternatives:** `drive.readonly` (rejected by the owner, and a restricted scope); a web Picker page hosted by us (needs an API key and a bridge page); a `WKWebView` sign-in (blocked by Google).

### Picked folders: list what Google lets the app read, and say so

- **Chosen:** list the children of each picked folder recursively under `drive.file`. Google may return nothing for a picked folder under this scope. In that case the import finishes with what was readable. The pre-pick sheet tells the owner to open the folder and select the photos inside (⌘A). An import that finds 0 files says the same.
- **Unverified:** whether a folder grant reaches its children under `drive.file`. Forum reports say no. The design works either way; the owner's E2E run settles it.
- **Alternatives:** refuse folder picks; ask for `drive.readonly`.
- **Skips:** Google Docs, Sheets and other `application/vnd.google-apps.*` files; shortcuts; trashed items; anything with an `appProperties` key starting `pv` (PhotoVault's own uploads). Duplicate names in one folder get distinct relative paths (`name (2).jpg`), in id order.

### Dropbox: Full Dropbox, PKCE, fixed loopback port, in-app folder browser

- **Chosen:**
  - A scoped app with the **Full Dropbox** access type, so `/Camera Uploads` is reachable.
  - Read-only permissions: `files.metadata.read`, `files.content.read`, `account_info.read`.
  - PKCE public client: no app secret in the binary. Only the App key (`DROPBOX_APP_KEY` in `Config/Secrets.xcconfig`) is needed.
  - `token_access_type=offline`.
  - Redirect `http://localhost:53682/oauth2/callback`. Dropbox needs an exact registered URI, so the port is fixed. The listener binds to 127.0.0.1.
  - The account token (`dropbox-account`) is kept only for browsing. Each import keeps its own copy (`import-<sourceId>`), so signing out or switching account does not break finished imports.
  - The folder browser is a SwiftUI sheet over `list_folder`, folders only. The owner can also choose the whole Dropbox (root path `""`).
  - Without an App key, the Dropbox item is disabled with a hint.
- **Alternatives:** the Dropbox Chooser (web JavaScript, needs a hosted page); app-folder access (cannot reach `/Camera Uploads`); moving the shared OAuth pieces into their own module now (more churn, no behaviour change).

### Cloud imports reuse `folder-<uuid>` ids; the kind lives on the source row

- **Chosen:** ids stay `folder-<uuid>`. `SourceConfig` gains optional fields: `account` (display email) and `remoteItems` (Drive picked ids, or one Dropbox root path). Rows written by 0.2.0 decode unchanged, so there is no migration.
- **Alternatives:** new id prefixes; a migration `v6`.
- **Why:** an import is a folder-shaped job whatever the provider. `ImportLocator`, the `x:` keys and recovery stay as they are.

### Read twice, as for Mac folders

- **Chosen:** inspect downloads each file to a scratch file, computes SHA-256 and reads its metadata, then deletes the scratch file. Export downloads the file again into staging, computing MD5 and SHA-256 on the way.
- **Alternatives:** adopt the scratch copy as staging; dedupe Drive files by `md5Checksum` before downloading.
- **Why:** keeps `ExportWorker`, the disk guard and crash recovery identical to Mac folders.
- **Known limit:** each cloud file is downloaded twice. Review if large video imports make it hurt.

### A revoked grant

- **Chosen:** the adapters throw `SourceError.accessRevoked` on `invalid_grant`, or on a 401 that still fails after one refresh.
  - On an open import, the source goes to `offline` with `statusReason = "signInRequired"`. The app shows "Cần đăng nhập lại" (sign in again) on that import, and the action reuses the start flow. The job holds.
  - On a closed import, the job is skipped (`resourceMissing`), so it is visible and the owner can retry it.
  - A network failure is not a revoked grant: an open import holds as `offline` and resumes by itself, as for a disconnected folder (FR-116).
- **Alternatives:** keep retrying hourly forever.
- **Why:** waiting cannot fix a revoked grant, and an endless retry raises a false "sync stalled".
- **Review later:** yes, after the owner tests revocation at the Google and Dropbox account pages.

## Tokens and privacy

- Each cloud import keeps its own refresh token in the Keychain (`import-<sourceId>`). At launch an import with a token is registered again.
- Factory reset (FR-117) deletes these tokens and the Dropbox account token, after it has tried to revoke them.
- Logs and the activity list never carry file names, paths, folder ids or emails. The email and the folder name show only in Settings, the menu bar card and the completion notification.

## Consequences

- Two new Keychain-held secrets per import, and one for the Dropbox account. Their deletion is part of factory reset.
- The owner needs two setup steps outside the app: enable the Google Picker API, and register a Dropbox app with the redirect and permissions in the [README](../../README.md#dropbox-setup).
- A Drive import of a picked folder may hold fewer files than the owner expects. The sheet and the empty-import message say so.
- No schema change: `source` rows and the sidecar `source` block carry the new kinds as strings.

## Not in this round

Continuous Dropbox or Google Drive sources, OneDrive, Flickr, and another Google account as a continuous source (Google Photos API: since 2025-03-31 the library API reads only app-created media, so the options are Drive, Takeout or the Photos Picker; see 0024). Removing an import from the list is still deferred, as in 0024.
