# Research: Google Picker (folder import), Dropbox (continuous source), roadmap sources

Timestamp: 2026-11-09 (research date). Budget: 5 research calls. Items tagged [UNVERIFIED] were not confirmed from a fetched primary source.

## TOC
1. Verdicts
2. Google Picker (Q1-Q4)
3. Dropbox (Q5-Q6)
4. Owner setup steps (Q7)
5. Roadmap sources
6. Spike plan (decisive unknowns)
7. Limitations and unresolved questions

## 1. Verdicts

| # | Question | Verdict |
|---|---|---|
| Q1 | Picker in native macOS app | Use Google's **desktop/mobile Picker flow** (system browser + `trigger_onepick`, result via redirect). Do NOT use WKWebView. Own hosted web Picker = fallback. |
| Q2 | drive.file + folder selection gives children access? | **Not confirmed. Likely NO** [UNVERIFIED]. Treat as false until spike proves otherwise. |
| Q3 | Second account source | Works in principle via second OAuth grant, same client ID, separate Keychain item. Child-file download under drive.file = [UNVERIFIED], spike required. |
| Q4 | Restricted-scope verification avoided? | **Yes** for drive.file (Picker adds no scope). drive.readonly would be restricted [UNVERIFIED]. |
| Q5 | Dropbox PKCE + loopback | PKCE without secret: expected yes [UNVERIFIED]. Use **Full Dropbox** access type to reach `/Camera Uploads`. |
| Q6 | Change tracking | `list_folder` + `continue` + `longpoll` is the standard. `content_hash` algorithm VERIFIED. |
| Q7 | Owner steps | Listed in section 4. |

## 2. Google Picker

### Q1. Native macOS options

Source: Google desktop/mobile Picker guide, https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker (fetched).

- Flow: Picker "redirects to the Google Picker within a new tab in the user's default browser". Not a webview.
- Auth request goes to `https://accounts.google.com/o/oauth2/v2/auth` with `prompt=consent` and `trigger_onepick=true`, plus `allow_folder_selection=true` to allow folder picks.
- Result: "OAuth redirects to the `redirect_uri` specified in the request with the following URL parameters appended": `picked_file_ids`, `code`, `scope`, `error`.
- App then exchanges `code` for a token and calls Drive API with the file IDs.
- Scope: "only the `drive.file` scope is permitted for these apps and it can't be combined with any other scope."
- Setup per guide: enable Google Picker API; separate OAuth client per platform. The guide does NOT mention API key, App ID, or project number.
- Guide does NOT address file:// or custom URL schemes. Its `redirect_uri` example is an https URL. Whether loopback `http://127.0.0.1:<port>` works with `trigger_onepick` is [UNVERIFIED]. Spike.

Options compared:

| Option | Mechanics | Needs | Policy fit | Effort | Rank |
|---|---|---|---|---|---|
| (ii-a) Google desktop Picker flow | System browser, `trigger_onepick`, selection returned in redirect | Existing desktop OAuth client, Picker API enabled | Google-documented native path | Low. Reuses loopback code path | **1** |
| (i-b) Own hosted web Picker page (photovault.annh.dev) in system browser | Our page loads Picker JS, returns selection to app via loopback/custom scheme | API key (HTTP referrer restricted to our origin), App ID = project number, `setOAuthToken`, `setOrigin` | Acceptable, but extra moving parts | Medium. Needs a bridge page + key | 2 (fallback) |
| (i) WKWebView loading Picker | Embedded webview | Same as above | Google disallows OAuth in embedded user agents [UNVERIFIED, from Google OAuth policy, not fetched]. Sign-in may fail | Medium | 3 (reject) |
| (iii) Newer "file picker" | Google Workspace Updates, Nov 2024: `setFileIds` on DocsView to pre-select files. Web Picker API, not native | Web origin | Not a native-app option | n/a | n/a |

Sources: Workspace Updates Nov 2024 post, https://workspaceupdates.googleblog.com/2024/11/new-file-picker-method-for-pre-selecting-google-drive-files.html (seen in search snippet, not fetched). No "Drive Picker for desktop" SDK found.

Web Picker details (API key restrictions, `setOrigin`, file:// rejection, `setAppId`) were NOT confirmed. The Picker overview page covers only `setOAuthToken` and says "the user must be signed in" (https://developers.google.com/drive/picker/guides/overview, fetched). Mark all web-Picker specifics [UNVERIFIED] until the web-Picker reference is read.

### Q2. Folder selection and drive.file

- Desktop guide: `allow_folder_selection=true` "allow[s] the user to also select folders". No statement on contents access.
- Overview page: no statement on folder contents (fetched).
- Search found no 2024/2025 announcement that folder selection grants access to children. The Nov 2024 announcement covers individual files only (see Q1).
- Secondary, old: a 2019 Apps Script community thread reports a Google engineer saying drive.file does not reach files inside a picked folder (https://groups.google.com/g/google-apps-script-community/c/_W-NKbttfbo, snippet only). A 2021 Stack Overflow Q reports the same limit (https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/68462168/google-drive-api-permission-to-children-files, mirror). Both old, [UNVERIFIED] for today.
- Verdict: **assume children are NOT granted**. Your recalled "2024/2025 announcement" was not found. Do not build on it.

Workaround if children are not granted (ranked):
1. User multi-selects all photos inside the picked folder in the Picker. Use `setSelectableMimeTypes` for `image/*,video/*` (Picker reference, not fetched). Multi-select cap: [UNVERIFIED]. Expect pagination in UI for large folders.
2. Fallback: user picks files in batches (UX cost, no API cost).
3. Rejected: `drive.readonly` (owner decision).

Note: even if picked files are granted per-file, `files.list?q='<folderId>' in parents` may return nothing under drive.file. That is the spike test.

### Q3. Different source account

- Picker lists files of whichever account the token belongs to. Source account needs its own sign-in.
- Same OAuth desktop client ID, second grant, separate Keychain item. Standard OAuth allows multiple grants per client [UNVERIFIED for this flow].
- `login_hint` (pre-fills account) and `prompt=select_account` (forces chooser) are standard Google OAuth parameters [UNVERIFIED for the Picker desktop flow; spike].
- Download: picked files are granted per-file per-token. `files.get?alt=media` with account B's drive.file token should work for picked IDs [UNVERIFIED, Google "Drive API auth" page not fetched]. Spike required.
- Caveat: `picked_file_ids` come back in the redirect of the flow that signed in account B. Make sure account A's token is not reused for those IDs.

### Q4. Verification and quota

- drive.file is a per-file, non-restricted scope. Picker adds no scope; the desktop flow forces drive.file only. So no restricted-scope verification beyond the existing consent screen.
- drive.readonly is a restricted scope [UNVERIFIED, from Google OAuth scope policy, not fetched]. Would trigger security assessment. Another reason to keep the owner's decision.
- Consent screen: existing branding/privacy/terms (README already documents this) is sufficient. Publish to production is still required (refresh-token expiry in testing, per README).
- Drive API quota per project [UNVERIFIED value]. Picker itself is free to use.

## 3. Dropbox

### Q5. Auth

- PKCE for native apps without secret: Dropbox supports PKCE (`code_challenge`, S256) [UNVERIFIED, Dropbox OAuth guide not fetched]. Keep app secret out of the binary.
- Loopback redirect `http://127.0.0.1:<port>`: Dropbox accepts localhost-style http redirects for development [UNVERIFIED]. Spike.
- `token_access_type=offline` returns a refresh token [UNVERIFIED]. Access tokens short-lived (≈4 h) [UNVERIFIED].
- App types (new apps are "Scoped access"):
  - **Full Dropbox**: access to all folders, including `/Camera Uploads`. Required for the stated use case.
  - **App folder**: sandboxed to `/Apps/<app name>`. Does not reach Camera Uploads. Reject.
- Scopes: `files.metadata.read` (list), `files.content.read` (download). Both needed.
- Production approval: dev mode is limited to the owner's account until more users are added. Dev mode allows up to 500 linked accounts (community reply, https://community.dropbox.com/en/discussion/846671/does-a-dropbox-app-have-a-limit-on-development-users, not official). Dropbox developer guide: production review starts after 50 linked users; owner has two weeks to apply, or new linking stops. Team-linked apps limited to 5 teams in dev (Dropbox staff reply, forum). Source: https://www.dropbox.com/developers/reference/developer-guide (search snippet). Whether `files.content.read` alone triggers production review: [UNVERIFIED].
- Owner's personal use: dev mode suffices for one account. Production approval only needed if others use the app.

### Q6. Change tracking

Verified:
- `content_hash` (https://docs.dropboxapi.com/dropbox-api/docs/technical-reference/content-hash, fetched; the old dropbox.com URL 301-redirects there):
  1. Split file into 4 MiB (4,194,304 bytes) blocks; last block may be shorter.
  2. SHA-256 each block.
  3. Concatenate the raw binary digests (not hex) in order.
  4. SHA-256 the concatenation; output hex.
  - Empty file: no blocks; the result is SHA-256 of the empty string.
  - Verified purpose: compare server copy against your copy without download.
  - Our own SHA-256 is a different value. To compare, compute Dropbox's algorithm locally. Cost: one local read of the file.

Unverified (from prior knowledge; check before implementing):
- `files/list_folder` with `path`, `recursive`, `include_media_info`, `limit`; returns `cursor` and `has_more`.
- `files/list_folder/continue` takes cursor and pages until `has_more=false`.
- `files/list_folder/longpoll` takes cursor and `timeout` (30-480 s), hits notify host, returns `changes` boolean. Client then calls `list_folder/continue`. Long-poll is cheap; use it for the watch loop.
- Cursor reset error (`reset`) after long gaps: client must re-list. [UNVERIFIED]
- `include_media_info`/`media_info`: media_info is populated only when requested. Deprecation status [UNVERIFIED]. Check current reference before relying on it. Use it only for capture time if needed; file modified time works as fallback.
- `files/download`: content via `Dropbox-API-Arg` header. Range support [UNVERIFIED]. Needed for resume on large videos.
- Rate limits: HTTP 429 with `Retry-After`. Backoff required [UNVERIFIED for exact limits].

Recommendation: list once with `recursive=true`, store cursor, then long-poll and `continue` on change. Do not poll `list_folder` on a timer.

## 4. Owner setup steps

### Google (Picker)
1. Cloud console → existing PhotoVault project → APIs & Services → Library → enable **Google Picker API**.
2. Keep existing macOS **Desktop app** OAuth client. Desktop flow uses the same client (guide says one client per platform).
3. Only if using web Picker fallback: Credentials → Create API key → Application restrictions: HTTP referrers → `https://photovault.annh.dev/*`. API restrictions: Picker API only. Note project number (App ID).
4. Confirm the OAuth consent screen stays "In production" (already done per README).
5. Spike (see section 6). No need to add a second client for account B.

### Dropbox
1. dropbox.com/developers/apps → Create app.
2. API: Scoped access. Access type: **Full Dropbox**. Name: unique.
3. Permissions tab: tick `files.metadata.read`, `files.content.read`. Submit.
4. Settings tab: Redirect URIs → add `http://127.0.0.1:<port>` (use the same port your loopback uses) [UNVERIFIED that Dropbox accepts it].
5. Copy **App key**. App secret is not needed for PKCE; do not ship it.
6. Enable additional users for testing if needed. Track the 50-user threshold for production application.

## 5. Roadmap sources (one paragraph each, [UNVERIFIED] unless noted)

**OneDrive (Microsoft Graph).** Public client OAuth 2.0 with PKCE; loopback `http://localhost` redirect is supported by Microsoft identity platform for desktop/public clients [UNVERIFIED]. Change tracking via `delta` on drive items (`/me/drive/root/delta` or `/drives/{id}/items/{id}/delta`), returning `@odata.deltaLink` for next sync. Scopes `Files.Read` (delegated). Mature API; delta token expiry needs re-sync handling. Cost: free for personal accounts.

**S3-compatible.** Access key + secret (or STS session token; SSO for AWS). No OAuth. Listing via `ListObjectsV2` with `ContinuationToken`. No native change feed: either periodic listing (cost per request) or bucket event notifications to SQS/SNS/EventBridge. For a backup-source use case, prefer event notifications where the bucket owner allows it. Works with MinIO, Backblaze B2 (S3 mode), Wasabi, R2. Key storage in Keychain.

**Flickr.** OAuth 1.0a (signature-based; no PKCE); requires API key + secret (app registration). Change tracking: `flickr.people.getPhotos` or `flickr.photos.search` with `min_upload_date` filter. Rate limits and API-only access to original size only with permission. Maintenance risk: legacy API surface, slow evolution.

Ranking for roadmap (by fit and effort): **1. OneDrive** (OAuth+delta, closest to existing Google model), **2. S3-compatible** (no OAuth, but two modes and bucket-owner setup), **3. Flickr** (OAuth 1.0a + weaker change feed).

## 6. Spike plan (decisive unknowns, ~2 hours, no product code)

1. Google desktop Picker flow: start loopback listener, open `trigger_onepick=true` URL with `allow_folder_selection=true`, pick a folder with 3 photos. Confirm redirect returns `picked_file_ids` on `127.0.0.1`.
2. Same token: `files.list?q='<folderId>' in parents`. If it returns children → Q2 solved. If empty → multi-select workaround.
3. Second account: sign in as account B via the same client with `login_hint`. Download a picked file with `alt=media`.
4. Dropbox: PKCE + `127.0.0.1` redirect; list `/Camera Uploads` with `recursive=true`; long-poll with cursor; download one file with Range header.

## 7. Limitations and unresolved questions

Limitations:
- Not fetched: Google drive.file scope reference (api-specific-auth), web Picker reference, Dropbox OAuth guide, Dropbox list_folder/longpoll reference, OneDrive, S3, Flickr docs. Roadmap facts are prior knowledge.
- Folder-contents result rests on old secondary sources; no current primary source found.
- No live API test performed; all "should work" claims need the spike.
- Dropbox production-approval details come from forum and community posts, not the official policy page.

Unresolved:
1. Does drive.file + folder pick expose children via `files.list`? (spike step 2)
2. Does the Picker desktop flow accept loopback `http://127.0.0.1` for `redirect_uri`? (spike step 1)
3. Max number of files multi-selectable in Picker? Pagination limits?
4. Does `files.content.read` alone trigger Dropbox production review?
5. Is `include_media_info` deprecated, and what replaces it?
6. Dropbox cursor reset behavior and longpoll timeout limits, current values?
7. Does drive.file download of picked files work for account B's token? (spike step 3)
8. Google Drive API quota for this project?

Next steps:
1. Run spike steps 1-3 (Google) and 4 (Dropbox).
2. Based on Q2 result, choose multi-select workaround or proceed with folder grant.
3. Create Dropbox app per section 4 (Full Dropbox, two permissions, 127.0.0.1 redirect).
4. Re-run this research on the specific unverified items only if the spike fails.
