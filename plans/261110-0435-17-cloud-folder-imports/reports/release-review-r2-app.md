# Release review r2: app target, config and docs (0.3.0)

- Snapshot: `b9c704f`, range `v0.2.0...b9c704f`. Focus: the fixes for round 1 in `21144c3..b9c704f` (`41c8456` app, `04fbcab` docs).
- Area: `PhotoVault/**`, `Sources/PhotoVaultAppSupport/**`, `Config/**`, `project.pbxproj`, README, docs, `site/public/privacy.html`.
- Checks I ran. The throwaway worktree and the probe have been removed.
  - `xcodebuild -scheme PhotoVault -configuration Release CODE_SIGNING_ALLOWED=NO`, with no `Secrets.xcconfig`: **BUILD SUCCEEDED**, with no compiler warnings. `PVDropboxAppKey` and `PVGoogleClientID` are empty.
  - The same build after copying `Secrets.xcconfig.example` to `Secrets.xcconfig`: **BUILD SUCCEEDED**. `PVDropboxAppKey` is empty, so the Dropbox item is disabled. This settles r1 m4.
  - `swift test --filter PhotoVaultAppSupportTests`: 156 tests in 26 suites passed.
  - Port probe: an `NWListener` bound to a fixed loopback port answered a request, was cancelled, and was bound again 0.5 s later without trouble. A quick Dropbox retry, for example after a wrong account is refused, does not hit `portInUse`.

## Round-1 findings, re-checked

| r1 | Status | Evidence |
|---|---|---|
| I1 import with no account | **Fixed** | Dropbox: the import button stays disabled until `browser.email != nil`. `load()` fetches the email before listing. `importDropboxFolder` takes a non-optional email and refuses a blank one. Google: refuses when `picked.email` is nil or blank, and does so before anything is stored. `isSameAccount(expected: nil)` is now false. |
| I2 abandoned sign-in blocks for 20 min | **Fixed** | `trackedFlow` keeps `cloudFlowCancel`. `BrowserWaitRow` with **Huỷ** shows in Sources and in the Dropbox sheet. Cancel reaches `LoopbackRedirectServer.awaitCode` through `withTaskCancellationHandler`, so it becomes `.cancelled` and closes quietly. Row sign-in buttons now show a notice instead of doing nothing. See m1 for what is left. |
| I3 FR-121 says skipped | **Fixed** | FR-121 now matches ADR 0026: closed imports wait hourly and the row shows `signInRequired`. `invalid_client` is listed as a trigger. |
| I4 privacy "stop all access" | **Fixed** | The privacy page now scopes app sign-out to the backup account and names the per-account Google and Dropbox revocation pages. It also says Start over deletes the tokens on this Mac. |
| m1 finished row waits up to an hour | Fixed (engine) | `resumeImportAfterSignIn` now calls `EngineQueries.releaseExports`. The ADR states it. |
| m2 identity is the email | **Open** | Not changed, and not recorded as accepted. See m3. |
| m3 Dropbox consent cancel shows an error | Fixed, too broadly | See m2. |
| m4 template ships a fake Dropbox key | **Fixed** | Verified by building, as above. |
| m5 localized sidecar name | **Fixed** | `SourceConfig.sidecarName` holds the folder name, `Google Drive` or `Dropbox`. `SidecarPlanner` uses `source.sidecarName`. Old rows decode with nil and fall back to the display name. `docs/sidecar-schema.md` matches. |
| m6 doc gaps | Partly fixed | The `PhotoVaultDropbox` row and `content.dropboxapi.com` were added. The file and line counts are still stale; see m5. |
| m7 Dropbox development-status linking | **Fixed** | README step 5 ("Enable additional users"). |

## Critical

None found.

## Important

**I1. README says throttling never fails a file. The code marks a throttled file failed after 24 hours, and the next README bullet says so too.**
- Where: `README.md:243`: "**Throttling:** … the import pauses for a short time and tries the same file again. No file is marked as failed for it."
- What the code does: `ImportStage+Ingest.swift:84-86`. `case .busy` goes through `waitsForRetry`, and `ImportHolds.shouldGiveUp` triggers after `giveUpAfter = 24h`, which sets `failed[path] = "read"`.
  - The import does not pause either. The busy group is skipped for 30 s while the other groups continue (ADR 0026 "One file that cannot be read now…").
  - Drive `downloadQuotaExceeded` is mapped to `busy`, and that quota often lasts about a day. So a popular file is exactly the case that reaches the 24-hour limit.
- Impact: the owner reads "no file is marked as failed" and then sees a "lỗi" count with no explanation. README line 245, FR-124 and the ADR all say the opposite of line 243.
- Fix: replace the bullet with something like: "When Google or Dropbox slows a download down, that file waits and is tried again while the rest of the import goes on. It counts under 'lỗi' only if it stays unreadable for 24 hours." Or merge it into the bullet at line 245.

## Minor

**m1. Huỷ in the wait row stays shown after the browser step. It cannot stop the import there, and cancelling can raise an error banner.**
- Where:
  - `AppModel+CloudImports.swift:173-185` (`trackedFlow`) and `:19-41`.
  - `DropboxAuth.swift` `tokenRequest`: `URLError.cancelled` becomes `SourceError.cancelled`.
  - `OAuthClient.perform`: `DriveTransportError.map(.cancelled)` becomes `.transient`.
- Scenario 1, after the browser redirect:
  1. The wait row still says "Đang chờ đăng nhập trong trình duyệt…" during the token exchange, `about.get`, `singlePickedFolderName` and `startImport`.
  2. `startImport` waits in the engine's exclusive lane until the cycle releases it.
  3. If the owner presses Huỷ there, nothing checks cancellation, and the import starts anyway.
- Scenario 2, cancel during the exchange:
  - Dropbox: `reportCloudFlowError` matches `error is SourceError` and shows "Không kết nối được tới Dropbox. Kiểm tra mạng…".
  - Google: shows the generic `showError`.
  - Google, cancel during `about.get`: the `try?` returns a nil email, which shows the red "Chưa kiểm tra được tài khoản…".
- The Dropbox sheet's own **Huỷ** stays enabled while `starting`. It dismisses the sheet, but the import still starts.
- Fix:
  - In `trackedFlow`'s catch, return quietly when `task.isCancelled`.
  - Call `try Task.checkCancellation()` before `DriveImportAuth.store` and before `startImport`, so a cancel that arrives in time really stops the import.
  - Optionally, hide Huỷ once the callback has arrived.

**m2. Every `LoopbackError` except timeout and cancel is now silent for Dropbox.**
- `DropboxAuth.swift:78` maps `default:` to `.denied`. That covers `authorizationDenied(any error code)`, `missingCode`, `requestTooLarge` and `stateMismatch`. `AppModel+CloudImports.swift:224` then returns quietly.
- Only `authorizationDenied("access_denied")` is the owner's own Cancel.
- Example: a redirect with `error=invalid_scope`, or any other provider error, leaves the browser on "Sign-in failed" and the app shows nothing.
- Fix: map only `authorizationDenied("access_denied")` to a quiet case, and keep a visible notice for the rest. Google uses the same broad mapping (`GooglePickerFlow.swift:80`, `.authorizationDenied` becomes `.cancelled`), so fix both or neither.

**m3. r1 m2 is still open: the identity is the email.**
- When the owner changes the email of their Google or Dropbox account, every re-sign-in of an older import is refused ("Hãy đăng nhập đúng tài khoản old@…"). A closed import's exports then wait hourly forever. Nothing is lost, because re-importing works.
- The plan's decision ("The email … is used for display only") is now wrong: the email is required and is the account check.
- Fix: use Dropbox `account_id` and Google `permissionId` as the identity. Or record the limit in ADR 0026 and the README "Cần đăng nhập lại" bullet, and update the plan's decision.

**m4. The new disk-wait status text.**
- `ImportProgressText.swift:22` uses "tệp". Every other Vietnamese string in the app says "file", for example "File đã upload vẫn giữ" and "\(n) file".
- "ổ đĩa" does not say which disk. The owner may think of the NAS destination, but the check is on the Mac's staging volume ("trên Mac").
- The menu card's `statusText` (`ImportsCard.swift:53-57`) shows the progress line whenever it is not empty, so the disk wait never appears there. Only the Settings row shows it.
- `"diskFull"` and `"signInRequired"` are string literals copied from the engine's internal `SourceStatusReason`.

**m5. `docs/architecture/codebase-summary.md` counts are stale, though it is dated 2026-11-10.**

| Folder | Doc says | Actual |
|---|---|---|
| `Sources/PhotoVaultDrive` | 20 files / 1,758 lines | 27 / 2,606 |
| `Sources/PhotoVaultAppSupport` | 26 / 1,734 | 27 / 1,864 |
| `PhotoVault/App` | 15 | 16 |
| `PhotoVault/Engine` | 13 | 14 (`CloudImportServices.swift` is not listed) |

- The Views row does not name `DropboxFolderSheet.swift`, `GoogleDriveExplainerSheet.swift` or `ImportRows.swift`.

**m6. The README bullet on Google's limit is narrower than the ADR.**
- `README.md:245` counts only Picker imports, and says only that the backup sign-in may be evicted.
- In practice:
  - Each **Đăng nhập lại** also creates a token.
  - The token Google evicts may be an older import's grant. That import then shows "Cần đăng nhập lại", as ADR 0026:111 says.
- Fix: add one clause.

**m7. The privacy page says uninstalling removes the local data. The Keychain tokens stay.**
- `privacy.html` ("Uninstalling the app and removing its folders in ~/Library removes the local data").
- These stay in the login Keychain after uninstall, and they are not revoked:
  - `import-*` refresh tokens, which can belong to other Google accounts;
  - `dropbox-account`, with read access to the whole Dropbox;
  - the backup token.
- The wording predates this release, but the cloud imports make the gap wider.
- Fix: "use Start over before uninstalling, or remove PhotoVault's access at the provider".

**m8. Factory reset does not cancel a running cloud flow.**
- Scenario:
  1. The owner starts **Đăng nhập lại** on a Google row.
  2. While the browser is open, they choose Start over.
  3. They finish the sign-in during the reset's `signOut()` await.
- `reconnectImport` then writes `import-<id>` after the Keychain sweep (`AppModel+FactoryReset.swift:20-24`). The new process wipes the database but not the Keychain, so a live refresh token is left behind with no row.
- The window is narrow. Fix: call `cancelCloudFlow()` at the top of `factoryReset()`.

**m9. Dropbox sheet: overlapping loads can show one folder's list under another folder's breadcrumb.**
- `DropboxFolderSheet.swift:105-117`: breadcrumb links stay enabled while `loading`, and `load()` has no generation guard.
- Scenario:
  1. Open B (trail `[A, B]`, loading).
  2. Click **Toàn bộ Dropbox**. The root listing finishes first, then B's listing overwrites `folders`.
  3. The breadcrumb now says root and the list shows B's subfolders. The first load to finish set `loading = false`, so the import button is enabled during the second load.
- The import still uses `currentPath`, so it does what the breadcrumb shows, but the screen contradicts itself.
- Fix: keep a load counter and drop stale results, or disable the breadcrumb while `loading`. This predates the round-1 fixes.

## Checked, no finding

- **Main actor:**
  - `runCloudFlow` and `trackedFlow` run on the main actor. `cloudFlowBusy` is set synchronously before the first suspension.
  - The inner `Task { @MainActor in … }` is the one `cloudFlowCancel` cancels.
  - The guards on `cloudFlowBusy` prevent overlapping tracked flows, so the `defer` cannot clear another flow's cancel handle.
- **Double taps:**
  - **Mở trình duyệt** is protected by the `cloudFlowBusy` guard.
  - **Từ Google Drive…** and **Từ Dropbox…** are disabled while busy.
  - **Nhập thư mục này** is protected by `starting`.
  - The sheet's **Đăng nhập lại** is disabled while busy.
- **Cancel during the token exchange, then orphan tokens:**
  - Google stores nothing before the account check. A failed `startImport` removes the grant.
  - Dropbox stores to `dropbox-account` or `import-<id>` only after `signIn()` returns and the account check passes.
  - A cancel never leaves a token without its row, except in the m8 window and in a crash, which r1 already accepted and factory reset sweeps.
- **Sheet dismissed mid-flow:** the flow runs in an unstructured task on the model. Its result updates a sheet model that is no longer shown, which does no harm. The wait row is still in Sources when Settings is reopened.
- **App quit mid-flow:** the loopback listener ends with the process, and nothing is persisted before the account check.
- **Wrong account, end to end:**
  - Google and Dropbox reconnect both run `accountUnknown`, then `isSameAccount`, before writing the Keychain or the config.
  - Re-signing in from the Dropbox sheet clears `browser.email`, so a new account's email is the one recorded.
  - A row with no account (only possible with pre-`41c8456` dev builds) now gets the "used before" notice instead of accepting any account.
- **Launch registration and factory reset sweep:** unchanged since r1 (`AppEnvironment`, `CloudImportKeychain`).
- **Privacy:**
  - The new strings (`waitingForBrowser`, `accountUnverifiedStartNotice`, the disk wait) contain no names.
  - The new log lines are fixed text.
  - `wrongAccountNotice` goes only to the in-app `notice` banner, which `showNotice` does not log.
- **Docs vs code:**
  - FR-119 to FR-124, the ADR 0026 sections added in this round, `sidecar-schema.md`, the privacy page's Dropbox and Google paragraphs, README Dropbox setup steps 1–6, and the Dropbox row in `system-architecture.md` all match the code.
  - The exceptions are I1, m5, m6 and m7.

## Unresolved questions

1. Was the owner's local `Config/Secrets.xcconfig` copied from the earlier template, the one with `DROPBOX_APP_KEY = replace-with-your-dropbox-app-key`? If so, the build still enables Dropbox with a client id that Dropbox rejects. Either the owner clears that value, or the app treats a `replace-` prefix as missing. I did not read the secret file.
2. From r1, still untested: does signing out of the backup revoke the same-account import grants at Google? Keep it in the owner's E2E run.

Counts: Critical 0 / Important 1 / Minor 9

Status: DONE_WITH_CONCERNS
Summary: All four Important findings from round 1 are fixed and verified. The app builds in Release with no Secrets file and with the template. One README contradiction about throttled files should be fixed before release; the rest are minor.
