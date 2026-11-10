# Release review r1: app target, config and docs (0.3.0)

- Snapshot: `21144c3`, range `v0.2.0...21144c3`. Area: `PhotoVault/**`, `Sources/PhotoVaultAppSupport/**`, `Config/**`, `project.pbxproj`, README, docs, `site/public/privacy.html`.
- Checks I ran, in a throwaway worktree that has since been removed:
  - `xcodebuild -scheme PhotoVault -configuration Release CODE_SIGNING_ALLOWED=NO` with no `Secrets.xcconfig`: **BUILD SUCCEEDED**. No compiler warnings. The built `Info.plist` has `PVDropboxAppKey` as an empty string, so the Dropbox item is disabled.
  - `swift test --filter PhotoVaultAppSupportTests`: 154 tests passed.
- Findings from the earlier report, re-checked:
  - I5 (same account, Google picks merged), I7 (Keychain listed at reset), I8 (finished rows wait and offer sign-in), M8, M10 (README documents the service), M11 (ADR text), M12 (documented as an accepted risk) and M14 are fixed.
  - M9 is fixed only for open imports; see m1.

## Critical

None found.

## Important

**I1. A cloud import can be recorded with no account, and then any account passes the "same account" check on sign-in.**
- Where:
  - `DropboxFolderSheet.swift:77,84`.
  - `CloudImportSupport.swift:70` (`isSameAccount` returns true when `expected` is empty).
  - `AppModel+CloudImports.swift:127,144`.
  - `GooglePickerFlow.email` (`try?` returns nil).
- Dropbox scenario:
  1. The sheet opens. `.task` awaits `currentAccountEmail()` before `load()`. During that await, `loading == false` and `failure == nil`, so **Import this folder** (the default action, Return) is enabled and the list shows "No subfolders".
  2. The owner presses Return, or the email call fails while listing works (`try?`). `importDropboxFolder(path: "", email: nil)` starts an import of **all of Dropbox** with `config.account == nil`.
  3. Later the grant is revoked, and the owner signs in again with another Dropbox account. `isSameAccount(nil, …)` is true, so the other account's token is stored as `import-<id>`.
  4. Reads by id then fail as `path/not_found` (`fileMissing`), so the pending files of that import are marked missing (open import) or skipped as `resourceMissing` (closed import).
- Impact: a whole-account import the owner did not choose. The guard that the ADR and README promise ("another account is refused") is silently off for that import, and pending files are lost from it. The originals stay in Dropbox, so importing again recovers them.
- Google: same hole when `about.get` fails after the code exchange (`email == nil`).
- Fix:
  - Disable the import button until `browser.email != nil` and the first `load()` has finished. For example, start with `loading = true`, or require `email` in the `disabled` condition.
  - Better: return `signIn.email` from `ensureDropboxSignedIn`, keep it with the account token, and refuse `importDropboxFolder` when the email is unknown.
  - For Google, treat a nil email at start as `PickerError.tokenMissing`-like: ask the owner to try again.

**I2. A sign-in the owner abandons blocks every cloud action for 20 min (Google) or 5 min (Dropbox), with no feedback and no cancel.**
- Where:
  - `AppModel+CloudImports.swift:65,120,163` (`cloudFlowBusy`).
  - `SourcesTab.swift:96,100`.
  - `GooglePickerFlow.pickTimeout = 20 min`, `LoopbackRedirectServer.defaultTimeout = 300 s`.
- Scenario:
  1. The owner clicks **Open browser** and closes the tab, picks the wrong browser profile, or Dropbox shows "invalid client_id" (see m4).
  2. **Từ Google Drive…** and **Từ Dropbox…** stay greyed out with no reason shown.
  3. **Đăng nhập lại** on import rows and in the Dropbox sheet stays enabled but does nothing (`guard !cloudFlowBusy else { return }`).
  4. The only way out is to wait up to 20 min or to quit PhotoVault.
- Fix:
  - While `cloudFlowBusy`, show "Waiting for the browser…" with a **Cancel** that cancels the flow's `Task`. `LoopbackRedirectServer` already maps cancel to `.cancelled`.
  - Disable the sign-in buttons while the flow runs, instead of making them silent no-ops.

**I3. Spec FR-121 says a closed import's jobs are skipped; the code and ADR 0026 make them wait.**
- Where: `docs/requirements/photovault-spec-v1.md:373`: "Import đã đóng: job bị bỏ qua (`resourceMissing`) để owner thử lại".
- What the code does: `ExportWorker+SourceFailures.swift:37-49` waits hourly and marks `signInRequired`. ADR 0026 and the README describe the same, and the ADR records the reversal.
- Why it matters: the spec is the living truth, so a maintainer following FR-121 would bring back the behaviour that lost files.
- Fix: rewrite the sentence to match the ADR: exports wait hourly with no error, the finished row shows "Đăng nhập lại", and sign-in must use the same account. While there, add `invalid_client` to the list of triggers.

**I4. The privacy policy says signing out of Google in the app stops all access. Import grants for other Google accounts survive it.**
- Where: `site/public/privacy.html:38` ("Signing out of Google in the app revokes them") and `:60` ("Sign out of Google in the app, or revoke access in your Google account, to stop all access").
- Scenario:
  1. The owner imports from a second Google account B through the Picker.
  2. They sign out of the backup account A. Only A's grant is revoked at Google.
  3. The `import-<id>` refresh token for B stays in the Keychain. It keeps being used, because closed imports are still read for destinations added later.
  4. No in-app action removes it except factory reset, and reset only deletes it locally; it is not revoked.
- Same for Dropbox: in-app **Sign out of Dropbox** deletes only `dropbox-account`, and each import keeps a copy of the same refresh token. The page does not claim otherwise, but it gives no in-app path either.
- Fix: state that each Google account used for an import must be revoked at its own myaccount.google.com/permissions page, or that **Start over** deletes all import tokens from this Mac. Also reword "stop all access".

## Minor

**m1. "Đăng nhập lại" on a finished row clears the warning at once, but its files wait up to an hour.**
- `resumeImportAfterSignIn` (`SyncCoordinator+Imports.swift:38`) clears the hold and the reason, but it does not reset `retryAt` on the resources whose export was deferred by `closedSourceRetry = 3600` (`ExportWorker.swift:281`).
- The owner sees nothing happen after signing in. Reset `retryAt` for that source's deferred exports in the same command. This is engine-owned; flagging it for r1-engine.

**m2. The account check compares emails.**
- After the owner changes the email of their Dropbox or Google account, every re-sign-in is refused ("Hãy đăng nhập đúng tài khoản old@…"). The import can then only be re-imported.
- Fix: store Dropbox `account_id` and Google `permissionId` (from `about.get`) as the identity, and keep the email for display only.

**m3. Pressing Cancel on Dropbox's consent page shows a red error ("Dropbox refused access.").**
- `LoopbackError.authorizationDenied` maps to `.denied` (`DropboxAuth.swift:78`, `AppModel+CloudImports.swift:202`).
- Google maps the same action to a quiet `.cancelled`, and the comment on `reportCloudFlowError` says cancel is "never an error banner".

**m4. `Secrets.xcconfig.example` ships `DROPBOX_APP_KEY = replace-with-your-dropbox-app-key`.**
- README Google step 8 tells the owner to copy the template and fill in only the Google values. The placeholder is non-empty, so `dropboxConfigured` is true, the Dropbox item is enabled, and Dropbox rejects the client id.
- This contradicts the README line "Without an App key, the Dropbox item … is disabled", and it triggers I2.
- Fix: leave the value empty in the template, with the hint in a comment, or treat a `replace-` prefix as missing.

**m5. The sidecar `source.name` is a localized UI string in two cases.**
- A Google multi-pick gives "3 mục từ Google Drive" or "3 items from Google Drive". A whole-Dropbox import gives "Toàn bộ Dropbox" or "All of Dropbox". Which language is frozen at import time.
- `docs/sidecar-schema.md:74` says "the folder's name".
- Fix: document this, or write a language-neutral name to the sidecar.

**m6. Doc gaps.**
- `docs/architecture/codebase-summary.md` (last updated 2026-11-09) has no `PhotoVaultDropbox` row and does not list the new Drive or app files. `system-architecture.md` links to it as the inventory.
- `system-architecture.md:272`, the Dropbox privacy row, omits `content.dropboxapi.com`, the host that serves `files/download`.

**m7. README Dropbox setup does not mention development-status linking.**
- A new Dropbox app in development status links only its owner's account until **Enable additional users** is used.
- To import from another person's Dropbox (a family member, for example), the owner needs that step; otherwise sign-in fails on Dropbox's page.
- Fix: add one line to step 1 or 2.

## Checked, no finding

- **Orphan state:**
  - Google: the grant is stored before `startImport`, and removed if `startImport` fails.
  - Dropbox: the account token is copied to `import-<id>`, then deleted if `startImport` fails.
  - A crash in between leaves an `import-*` item, which factory reset removes by listing the Keychain (`accountsToDelete`).
  - Double starts: `cloudFlowBusy` is set synchronously on the main actor before any await, and the sheet's `starting` flag covers it.
- **Factory reset:**
  - Lists the service with `kSecMatchLimitAll` and deletes `dropbox-account` and every `import-*`. It falls back to `dropbox-account` alone if listing fails.
  - The Google destination item is not caught by the filter.
  - `cloud-imports/<id>/remote-ids.json` lives under `layout.root` and is wiped. Scratch files live under `staging/` and are swept.
- **Launch registration:** `readableImports` plus `registrable(hasGrant:)` cover open and closed imports. A row without a token gets no adapter, and the engine marks it `signInRequired`.
- **Re-sign-in:** `registerSources` replaces the adapter by id (`SourceRegistry.add`). The Google config merge and the Keychain write happen only after the account check.
- **Privacy:**
  - New log lines carry only fixed text and `type(of: error)`.
  - The email appears in `ImportSnapshot` (not Codable, not persisted), Settings rows and the menu card. The notification uses the display name.
- **Config:**
  - `Secrets.xcconfig` is gitignored.
  - `PVDropboxAppKey` is wired from `DROPBOX_APP_KEY`.
  - The entitlements already include `network.server` for the loopback listeners.
  - `project.pbxproj` links the `PhotoVaultDropbox` product.
- **Owner setup:** the README Dropbox redirect `http://localhost:53682/oauth2/callback` matches `DropboxAuth.redirectURI`. The scopes match `DropboxAuth.scopes`. The Picker API step and the factory-reset text match the code.
- **CHANGELOG:** no 0.3.0 entry at `21144c3`. This is expected: `git-flow.cjs changelog --write` writes it on the release branch. The commits in the range use conventional prefixes.

## Unresolved questions

1. README and ADR state that signing out of the backup destination also revokes the same-account import grants at Google. That fits Google revoking the user–client grant as a whole, but it has not been tested. Include it in the owner's E2E run.
2. I1 fix: should a Dropbox import whose email is unknown be refused, or should the sheet hold the import button until the email is known? I recommend refusing, because the account guard depends on it.
