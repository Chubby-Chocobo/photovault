# Code review: Drive import reads folder contents (issue #32)

- Branch `fix/drive-import-reads-folder-contents`, `origin/release/0.4.0...HEAD` (4e674ea, c98191a), 22 files, +324/-38
- Checks run on a throwaway worktree at c98191a: `swift test` ran 1229 tests in 204 suites, all passed. The unsigned `xcodebuild ... -scheme PhotoVault` build succeeded.

## Verified (no finding)

- **Scope.** The destination `OAuthClient.scopes` is unchanged (`drive.file openid email`), and the new test pins it. Only `GooglePickerFlow.scope` changed. The Picker parameters are unchanged. The import adapter only sends GET requests (`item`, `children`, `download`). `drive.readonly` is never used for a write.
- **Release safety.** Covered cases:
  - An open import, including one held offline, is never listed.
  - `signInRequired` rows are excluded, so a re-sign-in in progress keeps its new token. `resumeImportAfterSignIn` clears the reason, but the jobs stay `pending` (`deferExports` only touches `resource`), so the grant is still kept.
  - `finishWhenDone` already requires no pending or uploading jobs.
  - Takeover and revival move `asset.source_id` to the new import.
  - Only `import-<id>` is deleted. `dropbox-account` can never be in the list.
  - The Keychain item is deleted before the adapter is dropped. At launch, an adapter is registered only when its token exists, so a crash between the two steps is harmless.
  - `hasGrant` makes the sweep idempotent.
  - A later need goes to `signInRequired`: `classifyFolderFailure` marks it, holds the exports for an hour and records no failure. The engine test confirms this.
- **Paths.** `RemoteIdIndex` keeps the path of a known id, so the dedupe only affects new ids. A re-sign-in with merged picks does not change paths or re-import files. The dedupe also fixes a bug that was there before: one id under two paths gave two entries with the same stable path.
- **Logs.** The new log lines contain no ids, names or emails.
- **Empty notice.** It uses `found` from the import_item counts. When every file is a duplicate, `found` is above 0, so the notice does not show. Cancelled imports are excluded in the row and in the notification (`newlyCompleted` only takes completed imports). The vi and en texts are present, and `UITextCoverageTests` passes.

## Critical

None.

## Important

**I1. The granted scope is never checked, so Google's granular consent can bring the original bug back without any sign.** `PickerFlow.run` → `OAuthClient.tokenRequest` checks only `drive.file` (`OAuthClient.swift:135`) and then drops `scope`. When an app asks for two non-sign-in scopes, Google shows checkboxes ([granular permissions](https://developers.google.com/identity/protocols/oauth2/resources/granular-permissions)).
- Scenario: the owner unticks "See and download all your Google Drive files". The token then has only `drive.file`, the picked folder lists empty, and the import finishes with 0 files. The hint then says "if imported with an older version…", which is the wrong cause.
- Fix:
  - Return the granted scopes from `OAuthTokens`.
  - In `GooglePickerFlow.run`, require `drive.readonly`. Throw a new `PickerError`, store nothing, and show a notice that names the checkbox.
  - Add a scripted test where the token response has no `drive.readonly`.
- Related: the import also fails with a generic error if the owner keeps `drive.readonly` and unticks `drive.file`. Decide whether the import really needs `drive.file` granted.

**I2. The empty-import hint for Google Drive points to an action that does not exist.** The text is "Nếu nhập bằng bản cũ, hãy đăng nhập lại và chọn lại thư mục." (`CloudImportSupport.swift:50-53`).
- The "Đăng nhập lại" button appears only for `signInRequired`. An empty, completed 0.3.0 import has no jobs, so the sweep releases its grant and the row shows no button.
- Even with a button, `reconnectImport` on a closed import does not list it again: `resumeImportAfterSignIn` only re-scans offline imports.
- The README and ADR 0030 say "import the folder again" (a new import), so the UI contradicts the docs.
- This is the only remedy shown to the users this fix is for.
- Fix: say "Hãy nhập lại thư mục: Nhập ảnh… › Từ Google Drive…" / "Import the folder again: Import photos… › From Google Drive…", and update the README line to match.

## Minor

**M1. `missingRemote` does not keep the grant** (`SyncCoordinator+Imports.swift:66`). `SchemaSnapshotCounters.openStates` treats it as open.
- Scenario: an integrity check marks an imported file missing at the destination, and the sweep releases the grant. When the owner confirms "upload again" (T20), the job goes back to pending and the import asks for sign-in (with the `drive.readonly` consent again).
- The file can still be recovered, so no data is lost.
- Fix: add `'missingRemote'` to the list. Also document in FR-119 and ADR 0030 that re-uploads and retries after a release need a sign-in, not only "a destination added later".

**M2. The app-side sweep policy is in the app target and has no test** (`AppModel+CloudImports.swift:129-144`). `code-standards.md` puts logic in `PhotoVaultAppSupport`. Nothing tests that only `import-<id>` is deleted, that `dropbox-account` is never touched, that the adapter is dropped only after the delete succeeds, or that ids without a grant are skipped. Issue acceptance "Token import bị xoá đúng lúc. Có test." is met only at the engine query level.
- Fix: move the loop to AppSupport (for example `CloudImportKeychain.release(ids:hasGrant:delete:)`) and test it.

**M3. Engine test gaps.** No test covers the `signInRequired` exclusion or the `deleted_at IS NULL` filter. `anOpenImportKeepsTheGrant` creates a harness at line 443 that it never uses.

**M4. The sweep is not serialized with the cycle.** A `requestSync` that returns `.queued` runs `releaseFinishedImportGrants` while another cycle is still running.
- If a destination's jobs are created after the sweep's read and before its delete, the first export finds no adapter and the import shows `signInRequired`. The end state is the designed one; only the timing differs.
- Fix (optional): do the check and the delete inside `exclusive`, with the coordinator taking a delete closure.

**M5. Per-cycle cost grows with history.** Every cycle runs one `EXISTS` per closed cloud import forever, including imports already released, which scan all their `done` jobs. Each one also does a Keychain read on the MainActor.
- Fix: filter the ids by `hasGrant` before the DB query, or pass the ids in.

**M6. A revoked token is never cleaned up.** A closed import stuck in `signInRequired` whose jobs then finish or are cancelled (destination removed) is excluded forever. Its dead `import-<id>` item stays in the Keychain until Start over.

**M7. The explainer sheet overstates what is deleted.** "…PhotoVault xoá nó khi nhập xong" / "PhotoVault deletes it when the import is done" (`GoogleDriveExplainerSheet.swift:17-18`).
- Only the token on this Mac is deleted, and only after the uploads finish. The `drive.readonly` grant stays in the Google account until the owner removes it.
- Not revoking is right: Google's revoke drops all of the client's grants for that account, which would also sign out a backup destination on the same account. The text should still say what actually happens.
- `privacy.html` is accurate ("from this Mac"). ADR 0030 rejects "a broad read grant for no purpose", but the grant does persist on Google's side: add that to its Consequences.

**M8. The "deeper path" rule covers picked files, not picked folders.** A picked folder that also sits inside another picked folder is walked once, under whichever root sorts first by Drive id (the `visited` set plus `ImportNames.assign`). Its files can end up under the shallower path. No data problem, but ADR 0030 and FR-119 describe it more broadly than the code does.

**M9. The launch notice is now noise.** "N cloud imports have no stored token" (`AppEnvironment.swift:193`) will fire on every launch for every released import, and it used to mean something was wrong.
- Fix: count only open imports, or imports with `signInRequired`.

**M10. Wording nit.** "Thư mục này… / This folder…" is shown even when the owner picked individual files.

## Unresolved questions

1. Can Google Workspace (school or work) accounts use the import at all? Their admin policy may block restricted scopes, and the README does not say. The owner's real run will only cover their own account.
2. ADR numbers 0028 and 0029 are skipped. Are they reserved by in-flight branches?

Counts: Critical 0 / Important 2 / Minor 10

Status: DONE_WITH_CONCERNS
Summary: The release logic is safe: no case found where a grant that is still needed gets deleted without the import falling back to `signInRequired`. Destination scope, Picker parameters and import paths are unchanged, and the suite and app build pass. Two Important items: the granted `drive.readonly` scope is never checked, and the empty-import hint tells owners to use a sign-in button that is not there.
