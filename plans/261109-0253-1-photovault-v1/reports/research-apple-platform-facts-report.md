# Research: Apple Platform Facts for Sandboxed macOS 14+ Menu-Bar Backup App

Date: 2026-11-09 | Status: PARTIAL. 1 of 5 fetches yielded primary content.

## Verdict Legend
- Confirmed: stated in fetched primary source.
- Contradicted: fetched source disagrees with the assumption.
- Not documented: no fetched source says it either way.
- Unverified: source fetch failed. Treat as open, not as true or false.

## Sources (5-call budget)
| # | URL | Result |
|---|---|---|
| S1 | https://developer.apple.com/documentation/photokit/phphotolibrary/fetchpersistentchanges(since:) | HTTP 404 (slug wrong or moved) |
| S2 | https://developer.apple.com/documentation/photokit/phassetresourcemanager/requestdata(for:options:datareceivedhandler:completionhandler:) | HTTP 404 |
| S3 | https://developer.apple.com/documentation/photokit/phassetresourcetype | Title only, no body |
| S4 | https://developer.apple.com/documentation/servicemanagement/smappservice | Title only, no body |
| S5 | https://sqlite.org/pragma.html | Full content (official SQLite docs, maintainer-authored) |

Not consulted: Apple Platform Security guide, WWDC sessions, Security framework/keychain docs, sandbox/bookmark docs, CLGeocoder docs. Gemini path not used.

## Item Results

### 1. PhotoKit persistent change history
- Verdict: **Unverified** (S1 404).
- Consequence: do not design around token lifetime, retention window, or expiry triggers until a spike confirms them against the SDK on macOS 14.
- Action: on first run, store the token and handle `persistentChangeTokenExpired` by falling back to a full scan. Do not assume incremental sync is reliable.

### 2. Cloud identifier mappings
- Verdict: **Unverified**. Not fetched.
- Consequence: cloud IDs as a cross-library or cross-device key stay unproven. Store local identifier plus asset fingerprint (resource size, dates, original filename) as a fallback key.

### 3. `PHAssetResourceManager.requestData` streaming and cancel
- Verdict: **Unverified** (S2 404).
- Consequence: the streaming-without-full-download assumption for Optimize Mac Storage originals is unproven. Multi-GB videos are a memory and disk risk until measured. Spike it: write chunks straight to the destination file, and measure peak RSS and temp disk use on a multi-GB iCloud-only video.
- Cancel and completion-after-cancel behaviour: unknown. Guard the completion handler with an idempotent state flag.

### 4. `PHAssetResource` types (edited, paired, RAW+JPEG, burst, screenshots)
- Verdict: **Unverified** (S3 gave no body text).
- Case names I recall (`fullSizePhoto`, `fullSizeVideo`, `adjustmentData`, `pairedVideo`, `fullSizePairedVideo`, `alternatePhoto`) are from memory only. Confirm each against the SDK header.
- Consequence: the backup must enumerate all resources per asset (not just the primary), and must store `adjustmentData` alongside edited renders, or edits cannot be restored faithfully.
- Burst, screenshot, and screen-recording subtype bits: not verified.

### 5. Data-protection keychain on macOS (`kSecUseDataProtectionKeychain`)
- Verdict: **Unverified**. Not fetched.
- Working assumption to test, not a fact: the data-protection keychain needs a signed app with a keychain-access-groups entitlement, and unsigned or ad-hoc builds get -34018 (errSecMissingEntitlement).
- Consequence: personal-team signing may still need a provisioning profile for the entitlement. Test this with a minimal signed build before relying on keychain storage for backup credentials or keys.
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: not verified for macOS.

### 6. App Sandbox: bookmarks, network server, Application Support
- Verdict: **Unverified**. Not fetched.
- Points to verify: `.withSecurityScope` bookmarks need the `files.bookmarks.app-scope` entitlement. Stale bookmarks must be refreshed. SMB volumes may need re-resolution after remount.
- Loopback listener needs `com.apple.security.network.server`. Photos-library entitlement name: not verified.
- Container redirect: sandboxed apps write under `~/Library/Containers/<bundle-id>/Data/Library/Application Support`. Treat this as the expected path until checked.

### 7. Filesystem durability: F_FULLFSYNC, RENAME_EXCL, SQLite
- Verdict on SQLite claims: **Confirmed** (S5, 1 source; needs a second to meet the 3-source bar).
  - `PRAGMA fullfsync` defaults to off. Only macOS supports `F_FULLFSYNC`. `checkpoint_fullfsync` is also off by default.
  - `synchronous=FULL` in WAL mode adds a WAL sync after each commit, which makes transactions durable across power loss.
  - `synchronous=NORMAL` in WAL can roll back a committed transaction after power loss or crash.
  - `synchronous=EXTRA` is no different from FULL in WAL mode.
  - Consequence: plain `synchronous=FULL` does not use `F_FULLFSYNC` on macOS. The app must set `PRAGMA fullfsync=ON` explicitly if it needs drive-level flushing.
- `fcntl(F_FULLFSYNC)` support on APFS, exFAT, SMB: **Not documented** in S5. Not verified elsewhere.
- `renameatx_np(RENAME_EXCL)` support on APFS, HFS+, exFAT, SMB: **Unverified**.

### 8. `SMAppService.mainApp` login item
- Verdict: **Unverified** (S4 title only).
- Recall, not verified: the API exists on macOS 13+, and `.requiresApproval` is a status case. Whether `/Applications` is required is unknown.
- Consequence: test with the app installed in `/Applications` and signed with personal team. Also test status after reboot.

### 9. `CLGeocoder` limits and data sharing
- Verdict: **Unverified**. Not fetched.
- Working assumption: reverse geocoding sends the coordinate to Apple's servers, and requests are rate-limited. Confirm before shipping any location feature.
- Consequence for backup: if location labels are optional, keep them off by default and disclose it. This is a privacy and YAGNI call, not a platform fact.

## Trade-off Matrix: SQLite durability settings (macOS, WAL)

| Option | Power-loss durability | Write cost | Complexity | Verdict |
|---|---|---|---|---|
| WAL + `synchronous=NORMAL` | Can lose last commits | Low | Low | Reject for backup manifest |
| WAL + `synchronous=FULL` | Durable (per S5) | Medium | Low | Acceptable fallback |
| WAL + `synchronous=FULL` + `fullfsync=ON` | Strongest on macOS (drive flush) | Highest | Low (2 pragmas) | Recommended |

Performance cost of `fullfsync=ON` is not measured here. Benchmark on the target volume.

## Ranked Recommendations
1. Manifest/state DB: WAL + `synchronous=FULL` + `fullfsync=ON`. Source: S5. Adoption risk: none (mature, public-domain SQLite).
2. Spike before architecture lock: items 1, 3, 8 (PhotoKit change history, streaming, login item). These drive the core sync design and are unverified.
3. Spike before keychain use: item 5, using a minimal personal-team-signed build.
4. Defer: CLGeocoder (item 9) unless location labels are in scope.

Architectural fit: no project stack details were provided in this research, so fit judgments are limited to platform constraints.

## Common Pitfalls
- Assuming `synchronous=FULL` means `F_FULLFSYNC` on macOS. It does not by default (S5).
- Assuming PhotoKit history never expires. Not verified; handle the expiry error path from day one.
- Writing whole multi-GB originals to a temp file before the backup step. Unverified streaming behaviour makes this a risk.

## Unresolved Questions
1. Correct Apple doc slugs for S1 and S2 (both 404), so the SDK facts can be checked.
2. Persistent change retention window and expiry triggers (item 1).
3. Whether `requestData` streams chunks for iCloud-only originals, and chunk size (item 3).
4. Exact `PHAssetResourceType` cases and availability on macOS 14 (item 4).
5. Keychain entitlement and -34018 behaviour under personal-team signing (item 5).
6. SMB bookmark behaviour after remount (item 6).
7. `F_FULLFSYNC` support per filesystem (item 7), and `RENAME_EXCL` support.
8. `SMAppService` location requirement (item 8).
9. `CLGeocoder` rate limit and data sharing (item 9).

## Status / Summary
- Status: PARTIAL. 1 of 9 items backed by a fetched primary source (item 7, SQLite portion). 8 of 9 unverified. Research budget (5 calls) exhausted.
- Summary: SQLite durability is confirmed, and the macOS gotcha is that `synchronous=FULL` does not use `F_FULLFSYNC` unless `fullfsync=ON` is set. The PhotoKit, keychain, sandbox, login-item, and geocoder assumptions are unverified. Run spikes for items 1, 3, 5, and 8 before committing to the design.
