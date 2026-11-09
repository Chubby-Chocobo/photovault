# Research: Google Drive API v3 + OAuth desktop assumptions (macOS backup app)

Timestamp: 2026-11-09 02:53 (local). Scope: verify app assumptions against official Google docs only.

## TOC
1. Sources and method
2. Verdicts (items 1-7)
3. Ranked actions
4. Unresolved questions

## 1. Sources and method

| # | Source | Covers |
|---|---|---|
| S1 | https://developers.google.com/drive/api/reference/rest/v3/files/generateIds | item 1 |
| S2 | https://developers.google.com/drive/api/guides/api-specific-auth | item 2, scope sensitivity |
| S3 | https://developers.google.com/drive/api/guides/manage-uploads | item 4 |
| S4 | https://developers.google.com/drive/api/guides/handle-errors | item 5 |
| S5 | https://developers.google.com/identity/protocols/oauth2/native-app | item 7 |

- Budget: 5 primary sources (max 5 research calls). No WebSearch fallback, no second source per claim. Claims are single-source (official) only.
- Quotes are WebFetch summaries of the pages, not verbatim. Re-verify wording before citing in code comments.
- Items 3, 6, and several sub-claims were not covered by S1-S5. Marked "Not documented" = not in S1-S5, not "false".
- Gemini not used (research budget capped; WebFetch direct).

Legend: **C** = Confirmed, **X** = Contradicted, **ND** = Not documented in S1-S5.

## 2. Verdicts

### Item 1: files.generateIds (S1)

| Claim | Verdict | Evidence / consequence |
|---|---|---|
| `type=shortcuts` valid | **C** | "Supported values are `files` and `shortcuts`." "`shortcuts` are only supported in the `drive` `space`." |
| `space=drive` valid | **C** | Values: `drive`, `appDataFolder`. Default `drive`. |
| IDs usable for folders | **ND** | Page says `space` sets "the type of file that can be created"; folders not named. Test empirically. |
| IDs usable for files / shortcuts | **C** (files, shortcuts) / ND (shortcuts by create call) | IDs usable in create or copy requests. |
| Validity duration | **ND** | No statement. Do not assume a window. Generate close to use. |
| 409 on reuse (files.create) | **ND** | No mention. |
| 409 on reuse (resumable initiation) | **ND** | No mention. |
| `count` max | **ND** | "The number of IDs to return." No max given. |

Consequence: Use generated IDs for create, but keep idempotency on our side. Persist the ID in the local DB before the create call. On any ambiguous failure, look up by ID before creating again. Do not depend on 409 semantics until tested.

### Item 2: drive.file scope (S2)

| Claim | Verdict | Evidence / consequence |
|---|---|---|
| Scope class | **C** | drive.file is **non-sensitive** (S2 table). Not restricted. |
| Access model | **C** | Access to files the app creates, or files the user "opens with an app or … shares with an app" (Picker or app's own picker). |
| Create shortcuts to own files | **ND** | Shortcuts not addressed. |
| List own files after reinstall / new session (same client ID) | **ND** | Not addressed. |
| Sees files user moved into app folders | **ND** | Not addressed. Inference only: drive.file is a per-file grant model, so moved files probably stay accessible only if app created them. Verify. |
| Untrash own files | **ND** | Not addressed. |
| Read/write appProperties | **ND** | Not addressed (S1-S5). |

Consequence: Biggest unverified risk in the app. Shortcut layout, folder-based discovery, and restore-from-trash all rest on ND claims. Design: local DB is source of truth for file IDs. Do not rely on folder listing to rediscover backups after reinstall until tested.

### Item 3: appProperties limits and queryability

**ND.** Not in S1-S5. Need Drive "properties" guide (not fetched). Do not rely on any numeric limits from memory.

### Item 4: Resumable uploads (S3)

| Claim | Verdict | Evidence / consequence |
|---|---|---|
| Chunk size multiple of 256 KiB | **C** | "multiples of 256 KB (256 x 1024 bytes)". Only final chunk may differ. |
| 308 = continue | **C** | "A `308 Resume Incomplete` response indicates that you must continue to upload the file." |
| No Range header = no bytes received | **C** | "If the response doesn't have a `Range` header, no bytes have been received." |
| Range header semantics | **C** | Example `bytes=0-42` = first 43 bytes received. Resume from last byte + 1. |
| Status query `Content-Range: bytes */<total>` | **C** | Empty PUT with `*/2000000` for 2,000,000-byte file. Use `*/*` if total unknown. |
| Session URI lifetime one week | **C** | "A resumable session URI expires after one week." Page also says one week of inactivity (wording per summary). |
| 404 on expired session = restart | **C** | "A `404 Not Found` response indicates the upload session has expired and the upload must be restarted from the beginning." |
| 410 behavior | **ND** | Not mentioned. Treat 410 like 404 only after testing. |
| Zero-byte file via resumable | **ND** | Not mentioned. Use multipart/simple create for empty files until tested. |
| md5Checksum right after upload (binary) | **ND** | Not mentioned. Verify by `files.get?fields=md5Checksum` after finish; test on real binaries. |

Consequence: Chunk size, 308/Range logic, and expiry handling are safe to implement now. Session expiry = 7 days: persist session URI with timestamp; on 404 restart whole file (no partial resume past 7 days). Handle 410 and zero-byte as untested branches.

### Item 5: Error reasons and limits (S4)

| Claim | Verdict | Evidence / consequence |
|---|---|---|
| 403 `userRateLimitExceeded` | **C** | Per-user limit. Fix: raise quota in Cloud project. Retry with backoff. |
| 403/429 `rateLimitExceeded` | **C** | 403: project rate limit, use backoff. 429: "too many requests… use exponential backoff." |
| 403 `dailyLimitExceeded` | **C** | Project daily API limit reached. Fix: remove "Queries per day" caps. Not a transient retry case. |
| 403 `storageQuotaExceeded` | **C** | User storage full. Not retryable. Surface to user. |
| 403 `insufficientPermissions` | **X** (name) | Not listed. Closest: `insufficientFilePermissions` (no write access to file). Code on the real reason string. |
| 429 | **C** | Same `rateLimitExceeded` reason, backoff. |
| Exponential backoff algorithm | **ND** | Recommended, but algorithm not on S4 (links to usage-limits page, not fetched). Use standard jittered exponential backoff; cap and max retries are our choice. |
| 750 GB/user/day upload limit | **ND** | Not in S4. Figure, unit (decimal vs binary), and error shape unverified. |

Consequence: Retry set = `userRateLimitExceeded`, `rateLimitExceeded`, 429, and 5xx. Stop-and-pause set = `dailyLimitExceeded`, `storageQuotaExceeded`. Fail-per-file = `insufficientFilePermissions`. Daily upload cap: design a generic "pause queue until next day" path, but do not hard-code 750 GB until verified.

### Item 6: `trashed` / `explicitlyTrashed` semantics

**ND.** Not in S1-S5. Do not assume child `trashed` propagates from parent. Test.

### Item 7: OAuth for desktop apps (S5)

| Claim | Verdict | Evidence / consequence |
|---|---|---|
| Loopback redirect `127.0.0.1` + random port | **C** | Recommended: "start an HTTP listener on a random available port." Forms: `http://127.0.0.1:port` or `http://[::1]:port`. |
| `localhost` as redirect | **C** (allowed, discouraged) | "may cause issues with client firewalls." Use 127.0.0.1. |
| PKCE required | **C** | "Always use PKCE." |
| S256 | **C** | Recommended. Base64URL (no padding) SHA256 of verifier. |
| `code_challenge_method` default | **C** | Default is `plain` if omitted. **Always send `S256` explicitly.** |
| Client secret confidential for Desktop | **X** (as a secret) | "Desktop apps are public clients and cannot keep secrets confidential." `client_secret` marked **Optional** in token/refresh tables. Do not treat it as a secret. |
| Refresh token expiry for "Testing" (7 days) | **ND** | Not on S5. Only says time-based grants expire after the specified duration. Need Cloud/OAuth consent doc (not fetched). |
| Refresh tokens always returned for installed apps | **C** | "Note that refresh tokens are always returned for installed applications." |
| Refresh token limits | **C** | Limit per client/user and per user across clients. Older tokens stop working when exceeded. |
| Refresh token rotation (new token each refresh) | **ND** | Not described. Always store the latest token if returned. Handle `invalid_grant` by re-auth. |
| Unverified app 100-user cap / warning screen | **ND** | Not in S5. |
| drive.file verification need | **Partial** | drive.file is non-sensitive (S2). Whether any verification or screen applies is ND in S1-S5. |
| ID token claims (`iss`, `aud`, `exp`) | **ND** | S5 says only `id_token` is a signed JWT when identity scope requested. No claim list. Do not rely on memory-based values; check OpenID Connect/Google ID token doc. |

Consequence: Loopback + PKCE S256 + 127.0.0.1 ephemeral port are safe. Do not rely on client_secret for security. Refresh-token lifetime under "Testing" is unverified: a 7-day expiry would break a backup app in Testing mode, so either publish to production or verify before release.

## 3. Ranked actions

1. **Run empirical spike (blocking).** Test on a throwaway Drive account + app: `generateIds` type=shortcuts, folder IDs, 409 on reuse (create + resumable), drive.file shortcut creation, list after reinstall with same client ID, moved-file visibility, untrash, appProperties, trashed propagation, md5Checksum, zero-byte resumable. Scope: drive.file only.
2. **Make local DB the source of truth** for Drive file IDs. Reduces dependency on ND listing/query behavior.
3. **Implement now (verified):** loopback 127.0.0.1 ephemeral port, PKCE S256 explicit, 256 KiB chunks, 308/Range resume, 7-day session expiry with restart on 404, error-reason routing (section 2, item 5).
4. **Get the ND numbers from the next docs pass:** appProperties limits, 750 GB daily upload limit, Testing-mode refresh-token expiry, unverified-app user cap. Fetch: Drive properties guide, Drive usage-limits guide, Google OAuth verification / app-publishing doc, OIDC ID token doc.
5. **Ship decision:** If the Testing-mode 7-day refresh expiry is confirmed, publish the OAuth app to production before any external-user beta. drive.file being non-sensitive reduces review burden, but this is not confirmed from fetched sources.

## 4. Unresolved questions

- Are generated IDs valid for folders, and for how long? Is 409 returned on reuse?
- Can drive.file apps create shortcuts, re-list after reinstall, see user-moved files, untrash, and use appProperties?
- appProperties: key/value byte limits, property count, total per file, and queryability for drive.file apps?
- Resumable: 410 behavior; zero-byte uploads; md5Checksum timing for binaries.
- Exact daily upload cap (750 GB decimal or binary?) and how it surfaces (403 reason? which one?).
- `trashed` propagation from parent folder; meaning of `explicitlyTrashed`.
- Refresh-token expiry for Testing-status apps; rotation behavior; unverified-app user cap and warning screen.
- ID token `iss` values, `aud`, `exp` requirements.
- Exact backoff algorithm recommended by Google (usage-limits page).

## Status / Summary

**Status:** Partial. 5 of 7 items have at least one Confirmed fact; key unknowns remain (items 1 sub-claims, 2, 3, 6, and parts of 4, 5, 7).

**Summary:**
- Confirmed: `type=shortcuts` (drive space only); 256 KiB chunks; 308/Range semantics; `*/total` status query; 1-week session expiry; 404 = restart; 127.0.0.1 ephemeral loopback; PKCE always, S256 explicit; Desktop clients treated as public; drive.file non-sensitive; error reasons `userRateLimitExceeded`, `rateLimitExceeded`, `dailyLimitExceeded`, `storageQuotaExceeded`.
- Contradicted: `insufficientPermissions` is not a listed reason (closest `insufficientFilePermissions`); client secret should not be treated as confidential.
- Not documented in S1-S5: appProperties limits, drive.file shortcut/relist/untrash behavior, ID validity and 409, 410, zero-byte resumable, md5 timing, 750 GB cap, trashed propagation, Testing 7-day refresh expiry, unverified 100-user cap, ID token claims.
- Biggest risk: drive.file behavior after reinstall and for moved files. Run the spike before committing to the sync design.
