# Release review r1: Core / Store / Engine (0.3.0, snapshot 21144c3)

- Scope: `git diff v0.2.0...21144c3` for `Sources/PhotoVaultCore`, `Sources/PhotoVaultStore`, `Sources/PhotoVaultEngine` and their tests. The app and adapters were read only where the engine contract depends on them.
- Tests: a throwaway worktree at 21144c3 ran `swift test`. 1149 tests in 192 suites passed: the 1145 committed tests plus 4 probe tests I added. The worktree has been removed.
- Probes, which pass on 21144c3 and so show the current behaviour:
  - P1: one `.unavailable` on a cloud read leaves the job `completed` with `failed: 1`.
  - P2: one oversized cloud file leaves `pending: 2`, `scanning`, with no reason, after 5 h.
  - P3: an always-busy file leaves `pending: 2` after 5 h.
  - P4: an offline import is probed 5 times in 5 runs with the clock stopped.
  - The probe file is kept at `/private/tmp/claude-501/-Users-annh-workspace-photovault/c95079e8-f124-4c29-8253-08dccc3843e6/scratchpad/ZZAuditR1.swift`.
- Earlier report (`code-review-261110-cloud-imports-report.md`):
  - Fixed: I1 for 429/5xx, which are now `busy`; I3 (`AdapterFault`, and the export maps unknown errors to `.unavailable`); I6 (disk check); I8 (closed imports wait and are marked `signInRequired`); M9 (`resumeImportAfterSignIn` clears the hold).
  - M4 no longer applies, because Dropbox reads by id.
  - I1 is still open for network drops; see Important 1.

## Critical

None found.

## Important

### 1. A network drop during one cloud download fails that file for good
- **Where:** `Sources/PhotoVaultEngine/ImportStage+Ingest.swift:51-54`. The adapter mappings that lead there are `DriveImportSource.swift:125` (`.offline → .unavailable`) and `DropboxClient.swift:200` (`offlineCodes → .unavailable`).
- **Scenario:**
  1. A cloud file is being downloaded for `inspect` when the Mac sleeps, Wi-Fi roams or the connection stalls. URLSession reports `networkConnectionLost` or `timedOut`, which the adapter maps to `SourceError.unavailable`.
  2. `process` calls `reachable()`. The probe is a small metadata call, and by then it succeeds.
  3. The item is marked `failed "read"` and nothing ever retries it. The job reaches `completed` with "1 lỗi", so the photo is never imported.
- **Evidence:** probe P1 ends `completed`, `[failed: 1, imported: 1]`.
- **Why cloud only:** for a Mac folder, `.unavailable` while the folder still answers is rare. For a cloud read it is routine.
- **Workaround:** import the same folder again.
- **Related, in the Drive adapter (for cloud-drive):** Drive 403 `downloadQuotaExceeded`, which lifts within 24 h, is not in `rateLimitReasons`. It becomes `.readFailed` and the same permanent `failed`.
- **Fix:** for `source.kind != .localFolder`, treat `.unavailable` from `inspect` like `.busy` when the probe succeeds: call `pauseBriefly(source.id)` and return `false`, so the item stays pending. If the probe fails, keep the current hold. Add a test that throws one `.unavailable` from `inspect` and expects 2 imported.

### 2. One cloud file that cannot be read now blocks the whole import, silently and without limit
- **Where:**
  - The disk check: `ImportStage+Ingest.swift:35-38`, with `hasRoomToDownload` at `:87-90`.
  - The `.busy` pause: `:48-50`.
  - The order: `ImportItemRepository.nextGroups` always returns the lowest pending `group_key` first.
- **Scenario A (disk):**
  1. A Dropbox `Camera Uploads` folder holds a 200 GB screen recording, and the Mac has 100 GB free.
  2. `hasRoomToDownload` is false for that item on every pass. The job calls `pauseBriefly` and returns.
  3. Every group sorted after that file is never read. The row stays `scanning` with no `statusReason`, so Settings and the menu card show progress that never moves and no reason.
  4. The only way out the owner can find is to cancel, which marks every remaining file cancelled.
  - The export side handles the same file through `ResourceGuard`'s too-large logic, so this gap is specific to import.
- **Scenario B (busy):** a file the provider answers with 5xx, or with a non-offline `URLError` on Dropbox, on every try blocks the job the same way. There is no attempt cap. An export that stays busy has no cap either (`ExportWorker.swift:280`, `held` with no attempt), so an `importing` job can also never finish.
- **Evidence:**
  - Probe P2: after 5 h the row is `scanning`, the reason is nil and the counts are `[pending: 2]`. `b.jpg` fits but is never read.
  - Probe P3: the same result with an always-busy `a.jpg`.
- **Fix:**
  - Make a pause skip only that group: keep processing later groups in the batch and leave the blocked item pending.
  - Count pauses per item (for example in `import_item.reason`). After N pauses, or when the file is larger than the volume could ever hold with the reserve, mark it `failed` with reason `disk` or `busy` so the job can finish and report it.
  - Set `statusReason = "diskFull"` while waiting for room, so the row can say why.

## Minor

### 3. An offline cloud import is probed on every pass with no cooldown
- **Where:** `ImportStage.swift:96-104`. Neither `reachable()` nor its caller `resume()` (`:77-79`) re-marks the hold for a source that is already `offline`.
- **Scenario:**
  1. Once the first 30 s cooldown has passed, every run of the import stage probes again. That means every round of every cycle while Photos work keeps the cycle looping.
  2. For a revoked grant, each probe is a token-refresh POST that gets `invalid_grant`. When the network hangs instead of failing fast, each probe can block the `.classify` step for up to the request timeout, which delays Photos backups in that round.
- **Evidence:** probe P4 counts 5 probes in 5 runs with the clock stopped.
- **Fix:** call `holds.mark(source.id, …)` on every failed probe, not only on a status change. Better, use a longer backoff for `signInRequired`, because only `resumeImportAfterSignIn` can fix it.

### 4. A finished cloud import with a revoked grant retries every file each hour, one token refresh per file
- **Where:** `ExportWorker+SourceFailures.swift:37-50`, with `runPass` (`ExportWorker.swift:64-109`).
- **Scenario:**
  1. A NAS destination is added after a 20 000-file Drive import finished, and the grant is revoked.
  2. Every hour, each due resource runs `beginExport` and then the adapter. The adapter refreshes the token (`DriveImportAuth.refresh` or `DropboxTokenAuthorizer.accessToken`) and gets `invalid_grant`.
  3. That makes about 20 000 token-endpoint calls per hour. They go to the same Google OAuth client as the backup destination.
- **Fix:** do either of the following.
  - After `markNeedsSignIn`, push `next_export_attempt_at` for every pending resource of that source in one UPDATE.
  - Or have the import auth fail fast after `invalid_grant` until the Keychain item changes.

### 5. A held export keeps an earlier `last_error`, so a waiting closed import can block "last successful sync"
- **Where:**
  - `ExportWorker.swift:280-284`: a `held` failure neither writes nor clears `resource.last_error`.
  - `SyncCoordinator+Cycle.swift:233-240`: only `offline` sources are excluded from the failing count.
- **Scenario:**
  1. On a closed cloud import, a resource once failed with `.readFailed`, which records `last_error`.
  2. The grant is then revoked. The export now waits hourly as designed ("waiting is not failing").
  3. The old `last_error` still counts. On a quiet day (`uploaded == 0`), `lastSuccessfulSyncAt` stops moving until the owner signs in.
- **Fix:** clear `last_error` on a held result. Or exclude resources of sources whose `status_reason = 'signInRequired'` from the failing count.

### 6. Signing in again on a finished import does not move up its waiting exports
- **Where:** `SyncCoordinator+Imports.swift:38-52`.
- **Scenario:**
  1. `resumeImportAfterSignIn` clears the mark and the hold.
  2. The resources of a closed import keep `next_export_attempt_at` up to 1 h ahead (`closedSourceRetry`).
  3. The "Đăng nhập lại" badge disappears, but nothing uploads for up to an hour.
- **Fix:** in the same write, set `next_export_attempt_at = NULL` for the source's resources that are in `staging_state = 'none'`.

### 7. A 0.3.0 database stops every cycle if 0.2.0 opens it again
- **Where:**
  - In 0.2.0, `SourceRepository.decode` parses `kind` with `row.enumValue`, so an unknown kind throws.
  - 0.2.0's `ImportStage.run` calls `fetchAll` on every pass.
- **Scenario:**
  1. After one Drive or Dropbox import, the owner reinstalls 0.2.0.
  2. Every cycle throws in the import stage, so Photos backups stop, with no message beyond a generic cycle error.
  3. There is no migration, so nothing marks the database as newer.
- **Fix:** accept and document it ("no downgrade after a cloud import"). Or add an empty `v6` migration, if the 0.2.0 GRDB migrator refuses unknown applied migrations. Check before relying on that.

## Checked, no finding

- **Config compatibility:**
  - `SourceConfig` uses synthesized `Codable` with optional fields, so 0.2.0 rows (`{"bookmark":…}` or `{}`) decode unchanged and nil fields are not encoded.
  - The new `SourceKind` values are strings on the existing column.
  - `readableImports` keeps the old filter for Mac folders.
- **Cycle safety:**
  - Every adapter call in `ImportStage` goes through `adapter {}`. Only `SourceError` and `CancellationError` leave it.
  - Non-`SourceError` failures on export map to `.unavailable`, except for Photos, which is unchanged.
  - Tests `anAdapterThatThrowsAnUnknownError…` cover both.
- **Open versus closed:**
  - `accessRevoked` on an open import, from the stage or from the export, sets `offline` / `signInRequired`.
  - On a closed import, a revoked grant or a missing adapter waits hourly with no error and sets the row's reason. A file that is missing while the source answers is still a permanent skip.
  - An open import with no adapter asks for sign-in.
- **Throttling:** `busy` on export records no error and costs no attempt (`held`).
- **Holds and concurrency:**
  - `ImportHolds` is shared by reference between the stage and the coordinator, behind an `NSLock`.
  - `resumeImportAfterSignIn` runs in the exclusive lane.
  - `setStatus` never reopens a cancelled job.
  - `ImportCompletion.finish` clears `status_reason`.
- **Crash safety:**
  - Listing still sets `listed_at` in its last batch.
  - Ingest commits per group in one transaction.
  - The scratch download is outside the transaction and swept at startup.
  - `remote-ids.json` is written before listing returns.
- **Photos:** paths are unchanged. `ErrorClassifier.classify(SourceError)` is used only for folder and cloud sources, and the `held` change applies only when `folder != nil`.
- **View fix (`ViewRules.swift:58-64`):**
  - A deleted photo now keeps its place shortcut, like By device and Favorites.
  - No new shortcut is created for a deleted photo: the sweep reads `liveAssetKeys` (`deleted_at IS NULL`), and `DirtyQueue` marks by geo cell only live assets.
  - `targetId` stays nil when the original was never uploaded.
- **Privacy:**
  - New log lines carry no ids, names, paths or emails ("source access revoked; import held", "source busy; import pauses briefly", "source adapter failed unexpectedly").
  - `account` reaches only `ImportSnapshot`. The sidecar `source` block carries the kind, folder name and relative path, as for Mac folders, and no email.

## Unresolved questions

1. Re-sign-in on Google merges the new pick into `remoteItems`, but `listed_at` is already set, so newly picked items are never listed. Is the re-pick only meant to restore the grant? If so, the sheet should say so (app scope).
2. Important 2 needs a product call: after N pauses, should an item that never fits or is always busy be marked `failed`, or should it wait forever with a visible reason?

Counts: Critical 0 / Important 2 / Minor 5
Status: DONE
