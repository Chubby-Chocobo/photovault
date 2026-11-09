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
- **Skips:** Google Docs, Sheets and other `application/vnd.google-apps.*` files; shortcuts; trashed items; anything with an `appProperties` key starting `pv` (PhotoVault's own uploads). Duplicate names in one folder get distinct relative paths (`name (2).jpg`), in id order the first time. Each import saves which remote file every relative path names in `remote-ids.json`, in its own folder under the app's data folder, and writes it before the listing returns. Reads resolve a path through that map. A path the map does not know triggers one shared new listing, which only adds paths and files that are new: a path never moves to another file. Drive calls pass `supportsAllDrives` and `includeItemsFromAllDrives`, so picks in Shared drives work.

### Dropbox: Full Dropbox, PKCE, fixed loopback port, in-app folder browser

- **Chosen:**
  - A scoped app with the **Full Dropbox** access type, so `/Camera Uploads` is reachable.
  - Read-only permissions: `files.metadata.read`, `files.content.read`, `account_info.read`.
  - PKCE public client: no app secret in the binary. Only the App key (`DROPBOX_APP_KEY` in `Config/Secrets.xcconfig`) is needed.
  - `token_access_type=offline`.
  - Redirect `http://localhost:53682/oauth2/callback`. Dropbox needs an exact registered URI, so the port is fixed. The listener binds to 127.0.0.1.
  - The account token (`dropbox-account`) is kept only for browsing. Each import keeps its own copy (`import-<sourceId>`), so signing out or switching account does not break finished imports.
  - Files are read by Dropbox id (`id:…`) and the same `remote-ids.json` map, so Unicode form and letter case of names do not matter. Folder names in relative paths come from the folder entries' own `name`, because Dropbox keeps the case of `path_display` only for its last component.
  - The folder browser is a SwiftUI sheet over `list_folder`, folders only. The owner can also choose the whole Dropbox (root path `""`).
  - Without an App key, the Dropbox item is disabled with a hint.
- **Alternatives:** the Dropbox Chooser (web JavaScript, needs a hosted page); app-folder access (cannot reach `/Camera Uploads`); moving the shared OAuth pieces into their own module now (more churn, no behaviour change).

### Cloud imports reuse `folder-<uuid>` ids; the kind lives on the source row

- **Chosen:** ids stay `folder-<uuid>`. `SourceConfig` gains optional fields: `account` (the email; it is also the account identity checked when the owner signs in again) and `remoteItems` (Drive picked ids, or one Dropbox root path). Rows written by 0.2.0 decode unchanged, so there is no migration.
- **Alternatives:** new id prefixes; a migration `v6`.
- **Why:** an import is a folder-shaped job whatever the provider. `ImportLocator`, the `x:` keys and recovery stay as they are.

### Read twice, as for Mac folders

- **Chosen:** inspect downloads each file to a scratch file, computes SHA-256 and reads its metadata, then deletes the scratch file. Export downloads the file again into staging, computing MD5 and SHA-256 on the way.
- **Alternatives:** adopt the scratch copy as staging; dedupe Drive files by `md5Checksum` before downloading.
- **Why:** keeps `ExportWorker`, the disk guard and crash recovery identical to Mac folders.
- **Known limit:** each cloud file is downloaded twice. Review if large video imports make it hurt.

### A revoked grant, and a throttled one

- **Chosen:** the adapters throw `SourceError.accessRevoked` on `invalid_grant` or `invalid_client` from the token endpoint, or on a 401 that still fails after one refresh. Any other refusal of the token endpoint is "unavailable", not "revoked".
  - On an open import, the source goes to `offline` with `statusReason = "signInRequired"`. The app shows "Cần đăng nhập lại" (sign in again) on that import, and the action reuses the start flow. The job holds.
  - On a closed import, the exports wait, as for a disk that is away: they retry hourly, record no error and do not count as a failing sync. The import row keeps `statusReason = "signInRequired"` and Settings shows "Đăng nhập lại" on the finished row. This also covers a cloud import whose token is missing at launch (no adapter). A file that is gone while the source answers is still skipped.
  - The email is the account identity for signing in again: accepted decision. If the owner changes the email of their Google or Dropbox account, every re-sign-in of an older import is refused and the owner imports again; nothing is lost. A provider account id would survive that but needs a second request and a migration of old rows.
  - Signing in again must be the same account (Google: same email, and the new pick is added to the old one; Dropbox: same email). Another account changes nothing and shows "Hãy đăng nhập đúng tài khoản <email>". A command to the engine then clears the hold, so the import resumes in the next cycle.
  - A network failure is not a revoked grant: an open import holds as `offline` and resumes by itself, as for a disconnected folder (FR-116).
  - A rate limit or a 5xx (Drive 403 `rateLimitExceeded`/`userRateLimitExceeded`, 429, 5xx; Dropbox 429, 5xx) is `SourceError.busy`: the item stays pending, the job is not marked offline and it waits a short cooldown (30 s) before reading again. An export retries later without costing an attempt.
  - An adapter throws only `SourceError` (or a cancellation). Anything else that still gets out is caught by the engine, which holds that job and goes on with the others, Photos backups included.
- **Alternatives:** keep retrying hourly forever; skip a closed import's jobs when the grant is revoked (the first version of this decision, reversed because it lost files that a new sign-in would have saved).
- **Why:** waiting cannot fix a revoked grant, so the open job says so; but a closed import's files are still wanted by a destination added later, so they wait instead of being given up.
- **Review later:** yes, after the owner tests revocation at the Google and Dropbox account pages.

### Disk space for the scratch copy

- **Chosen:** before a cloud file is downloaded to read its hash, the engine checks the free space of the staging volume against the file's size plus the critical reserve. When it does not fit, that file's group stays pending and waits; it is never marked failed for lack of room. While any group waits for room the row carries `statusReason = "diskFull"` and Settings says so; the reason clears once everything fits.
- **Why:** Mac folders are read in place; cloud files are not, and a very large video could fill the disk.

### One file that cannot be read now never holds back the import

- **Chosen:** a group that cannot be read now (not enough disk room; `busy`; a dropped connection or timeout on a cloud read while the probe still answers) is left pending and skipped for a cooldown (30 s), and the import goes on with the other groups. Only when nothing in a pass could be read does the whole job back off. A Drive 403 `downloadQuotaExceeded` counts as `busy`.
  - Each group that fails to read (busy, or a dropped connection while the probe answers) is retried after its own wait: 30 s, then twice as long each time, at most 1 hour. Groups that never failed are read first, in group order; failing groups come after them, soonest retry first. A few stubborn files therefore never keep the rest of the import from being read.
  - A group is given up as a whole (its files are marked `failed` with reason `read`, so the import can finish; the "lỗi" count shows them and the owner imports the folder again to retry) when it has failed at least 10 times and at least 24 hours of wall-clock time lie between its first and its latest failure. A failure counts only if the source's probe answered in that pass; when the probe fails the job goes offline and nothing is counted. A sleeping Mac or a gap between passes does not restart the count. The counts are in memory, so a relaunch starts them again; that only delays giving up.
  - Accepted trade-off: the probe is a small call to the provider's API, so a download-only outage that lasts more than a day while the API still answers can mark files failed. Importing the folder again brings them back.
  - The breaker only bounds how long a pass runs: after 3 groups in a row that had never failed before and fail now, the pass for that source stops and the source waits out the cooldown (30 s). Groups that were already failing do not count toward it, and failures in a pass that trips it still count toward giving up. While a cloud import is still reading, the app re-checks every 5 minutes, so a group is retried soon after its wait and not at the next hourly timer.
  - A file that waits for disk room has no limit: the owner can free space.
  - A Mac folder file that cannot be read still fails at once.
- **Alternatives:** pause the whole job on the first blocked file (the first version: one oversized or always-failing file stalled everything behind it, silently); give up after a number of attempts alone (counts depend on how often cycles run, wall-clock does not).
- **Why:** found in review as the way a big import could stay "scanning" for ever with no reason shown.
- **Review later:** no.

### A finished import with a revoked grant asks the provider once

- **Chosen:** the first export of a closed import that hits `accessRevoked` marks the row `signInRequired` and pushes the retry time of all that source's waiting exports one hour ahead in one statement and drops that source's candidates already queued in the pass, so the provider is asked once (at most as many times as exports run side by side) and not once per file; each hour it asks again. A waiting export clears any earlier recorded error so it cannot block "last successful sync". Signing in again clears the retry times of that source's exports, so they run in the next cycle. An import that is offline is probed once per cooldown (30 s; 10 min when only signing in helps), not on every pass.
- **Why:** otherwise every file of a 20,000-file import refreshed the token and failed the same way every hour.

### Loopback callback size

- **Chosen:** the redirect's request line may be up to 256 KiB, enough for the 5,376 picked ids the app accepts (budgeted at 48 bytes each). More ids than that are refused with `selectionTooLarge` and the browser page says so; ids are never dropped silently. A longer request line that carries the expected `state` (found by reading on, up to four times the limit, because Google may put it after the ids) gets the same page and ends the flow at once. A long request without the state is a stray one: it gets a 413 and the flow keeps waiting. The listener is bound to loopback only, so the larger limit costs nothing.

### Not supported: going back to 0.2.0 after a cloud import

- 0.2.0 cannot decode the new source kinds, so its cycles fail while such a row exists. There is no downgrade path and no migration marks the database as newer.

### Backup sign-out and imports of the same account

- Signing out of the Google backup revokes the app's grant at Google for that account; imports from the same account share the revocation and wait for a new sign-in. Imports from another Google account, and the Dropbox copies, keep their own grant until the owner removes the app's access at the provider or uses Start over (which deletes the tokens locally, without revoking).

## Tokens and privacy

- Each cloud import keeps its own refresh token in the Keychain (`import-<sourceId>`). At launch an import with a token is registered again.
- Factory reset (FR-117) lists the Keychain items of the app's service and deletes every `import-*` item and `dropbox-account`, whether or not a database row names them. It does not revoke them at the provider: every import copy shares the account's Dropbox refresh token, and revoking it would disable all of them.
- Signing out of the Google backup destination revokes the app's grant for that Google account at Google. Imports from the same account share that revocation: they then wait and show "Đăng nhập lại". Google also allows at most 100 refresh tokens per account for one client. Each Picker import and each "Đăng nhập lại" creates one, so very many of them can evict the oldest token, which may be the backup sign-in or an older import's grant; that one then asks to sign in again.
- The Dropbox redirect uses `localhost` while the listener binds `127.0.0.1` only. A browser that resolves `localhost` to `::1` could reach another program on that port; PKCE still stops that program from using the code. This is a known, accepted risk.
- Logs and the activity list never carry file names, paths, folder ids or emails. The email and the folder name show only in Settings, the menu bar card and the completion notification.

## Consequences

- Two new Keychain-held secrets per import, and one for the Dropbox account. Their deletion is part of factory reset.
- The owner needs two setup steps outside the app: enable the Google Picker API, and register a Dropbox app with the redirect and permissions in the [README](../../README.md#dropbox-setup).
- Each import keeps a small `remote-ids.json` in the app's data folder (`cloud-imports/<id>/`). Factory reset wipes the data folder with it.
- A Drive import of a picked folder may hold fewer files than the owner expects. The sheet and the empty-import message say so.
- No schema change: `source` rows and the sidecar `source` block carry the new kinds as strings.

## Not in this round

Continuous Dropbox or Google Drive sources, OneDrive, Flickr, and another Google account as a continuous source (Google Photos API: since 2025-03-31 the library API reads only app-created media, so the options are Drive, Takeout or the Photos Picker; see 0024). Removing an import from the list is still deferred, as in 0024.
