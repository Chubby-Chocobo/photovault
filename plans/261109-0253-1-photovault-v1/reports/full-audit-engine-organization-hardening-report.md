# Full audit: engine organization + hardening

Scope: every file listed in the brief (`Sources/PhotoVaultEngine`), the code paths they call (`UploadAttempt`, `StartupRecovery`, `FolderEnsurer`, `DirtyQueue`, `ViewDiff`, `ViewRules`, Drive `list`/`trashShortcut`), and the related engine tests.
Checks run: `swift test --filter PhotoVaultEngineTests` gave 262 tests in 39 suites, all passing. All findings below come from reading the code; none has a failing test yet.
Overlap with the parallel audits is cross-referenced, not repeated. Items fixed in rounds 1–4 are not repeated.

## Critical

### C1. An integrity check while the root (or a backup folder) is in the trash marks the whole archive `missingRemote`. Restoring it does not undo this, and the confirm button then re-uploads everything as duplicates.
- **Where:**
  - `IntegrityChecker.swift:37-38`: the only skip is `recoveryRequired` or no adapter, so a `paused(rootTrashed|folderTrashed)` destination is checked.
  - `IntegrityChecker.swift:156-176`: the Drive listing is `trashed=false` (`GoogleDriveDestination.swift:153`), so every file under the trashed root is absent. `stillThere` then sends one `files.get` per file, each answers trashed, and every file goes to `markMissing`.
  - Restoring does not heal: `RootProblemService.swift:39-50` (`recheck`), `:121-126` (`untrashAppItems`) and `DestinationHealth.swift:15-23` (automatic `active` once the root is back). Healing (`healReturned`, `:199-208`) happens only at the next check, 7 days later.
  - `JobTransitions.swift:177-185`: `reuploadConfirmed` clears `remoteId`, so each file is uploaded as a new file.
- **Scenario:**
  1. The owner trashes `Camera Uploads` by mistake.
  2. The destination becomes `paused(rootTrashed)`.
  3. The owner presses Settings › "Kiểm tra ngay", which loops over all destinations (`EngineHardeningCommands.swift:16-27`). The check makes N `files.get` calls and marks N files missing.
  4. The owner restores the root in Drive. The next cycle sets the destination back to `active`.
  5. The card still says "N file thiếu", plus the FR-61 notification.
  6. The owner presses Confirm and the whole archive is uploaded a second time into the restored root.
  - The same happens with `paused(folderTrashed)` followed by "Khôi phục giúp tôi".
  - The scheduled check (`IntegrityStage`) hits the same case when the root is trashed after step 1 of a long cycle.
- **Fix:**
  - In `checkDrive`, run `checkRoot` first. A trashed or missing root makes the check "unreachable" (skipped), and so does a destination whose status is `paused(rootTrashed|rootMissing|folderTrashed)`.
  - A file under a trashed ancestor belongs to the folder-trash flow, not to `missingRemote`.
  - After `recheck` / `untrashAppItems`, heal `missingRemote` jobs with a probe.

## Important

### I1. "Dựng lại view" does not bring back shortcuts or view folders the owner deleted, unless an integrity check ran first
- **Where:**
  - `ViewStage.swift:144-169`: `prepareRebuild` only resets `remote_folder` rows.
  - `ViewStage.swift:171-179`: `restoreRemoved` touches only `userRemoved` rows.
  - `ViewDiff.swift:49-56`: a `done` row with the same parent produces no operation.
  - The test hides the gap: `ViewRebuildTests.swift:43-55` calls `runIntegrityCheck` before `rebuildViews`.
- **Scenario:**
  1. The owner deletes `By device/` (or single shortcuts) in Drive.
  2. Nothing marks those rows, because detection happens only on a later `move` that gets 404, or in the 7-day integrity check.
  3. The owner presses "Dựng lại view". `prepareRebuild` finds the folders gone and invalidates them.
  4. The sweep sees every shortcut as `done`, so nothing is created. `finishRebuildIfDone` clears the flag. The view stays empty.
  5. Seven days later the integrity check marks those rows `userRemoved`, and they are never recreated without a second rebuild.
  - Also: shortcuts that ended `failed` on create (`ViewExecutor.swift:255`) are not reset by a rebuild either. See core S3 for the ViewDiff side.
- **Fix:** while rebuilding, run the shortcut reconciliation (a listing). At minimum, `markUserRemoved(under:)` for every view folder found gone, and reset `failed` rows, before the sweep.

### I2. A shortcut left in `trashPending` makes every later cycle fail at step 7
- **Where:**
  - `ViewExecutor.swift:52-58`: `finishTrashes` calls `trash()` with no error handling.
  - `ViewExecutor.swift:151-165`: only `.notFound` is caught.
  - `ViewStage.swift:59-62`: called at the start of every ViewStage run.
  - `SyncCoordinator+Cycle.swift:59-63`: the error ends the cycle.
- **Scenario:**
  1. A trash gets a 429 or 5xx inside `perform`. The handler returns `.stopped`, and the row stays `trashPending`. Only `finishTrashes` retries such rows.
  2. At the next round, the retry gets another 429, or a persistent 403. For example, the owner moved the shortcut into a folder shared by another account, which the adapter maps to `viewsNotPermitted`.
  3. The error escapes `ViewStage.run` and the cycle ends with `.failed`.
  4. Moves (step 8), place names (step 9), FR-53, integrity and `recordSuccess` never run. With a persistent error this repeats every cycle.
  5. `disable()` is never reached for `viewsNotPermitted` on this path.
- **Fix:** route `finishTrashes` through `perform`/`handle` (`.trash`), and stop on `.stopped`/`.retryLater` instead of throwing.

### I3. The integrity check trashes view shortcuts that belong to other PhotoVault roots in the same Google account
- **Where:**
  - `IntegrityChecker.swift:156-158`: `list(under: nil)` covers the whole account (`GoogleDriveDestination.swift:152-156`).
  - `IntegrityChecker.swift:238-252`: every `pvView` shortcut whose id is not in this database's `shortcut` table is trashed, 200 per run.
  - `RemoteInventory.swift:79-96` does the scoping correctly (`isUnderRoot`); the checker does not.
- **Scenarios:**
  - The owner changes root (FR-08), or picks "Upload lại vào thư mục mới". `dropDestinationKnowledge` deletes the shortcut rows (`RecoveryTriggers.swift:141-152`), so each check trashes 200 more shortcuts of the old root's views.
  - Two Macs back up to the same Google account into different roots. Each Mac trashes the other's shortcuts, and the other Mac's next check turns them into `userRemoved`, so they never come back. These are owner-visible items outside the app's current root.
  - Drive/photos S2 says this caller is "correct"; that holds only for its file checks.
- **Fix:** before treating a shortcut as a stray, check that it is under the current root (the same walk as `isUnderRoot`).

### I4. A Drive upload that resumes a session opened before its day was promoted records the day folder, but the file is in the month folder
- **Where:**
  - `UploadAttempt.swift:136-142`: a first upload commits `plan.parentLogical` from the current plan.
  - `UploadAttempt.swift:239-242`: the old session is resumed, and its parents were fixed when it started.
  - `JobTransitions.swift:72-74`: the session's parent is not stored.
  - `StartupRecovery.swift:113-120` already derives the real parent from `item.parentIds`; the live path does not.
- **Scenario:**
  1. A 2 GB video session is opened with parent `camera/2026/11`. The transfer is cut off by sleep or a quit, and the job returns to `pending` with its session.
  2. That day crosses N, for example during FinalizePass after a restart. `enqueueMoves` covers only `done` jobs.
  3. The next attempt ensures the day folder and resumes the session. Drive finalizes the file in the month folder.
  4. The commit stores `remote_logical_parent = …/2026-11-08`, and `enqueueMove(day → day)` is a no-op.
  5. The spec 8.7 invariant is broken for good and silently. The integrity check does not compare parents, and any later move removes the wrong parent.
  - NAS is not affected: it has no sessions, and planned paths are stored.
- **Fix:** map `result.parentIds` to a `remote_folder` row, as StartupRecovery does, and pass that as `uploadedParent`. Or store the session's parent logical with `sessionStarted` and use it on resume.

### I5. "Làm mới địa danh" (and, more mildly, a language change) rewrites every place-bearing sidecar and description twice, and empties "By place" for hours
- **Where:**
  - `GeocodeScheduler.swift:172-178`: `DELETE FROM geo_cache`, then an immediate sweep of sidecars, views and descriptions.
  - `OrganizationLookups.swift:18-25`: no cached cell means no place.
  - `ViewRules.swift:58-62`: no `en` geocode means the asset is not in `byPlace`.
  - `ViewDiff.swift:58-60`: anything not desired is trashed.
- **Scenario (50k assets, 10k cells):**
  1. The sweep runs in the next round, before almost any cell is geocoded again (20 requests per minute, about 17 h for 10k cells).
  2. Every JSON and XMP sidecar with a place gets a new hash and is uploaded at every sidecar destination.
  3. Every Drive description loses `Place:`.
  4. Every `byPlace` shortcut is trashed.
  5. Then, cell by cell, `markAssets(inCell:)` writes all of them again and recreates the shortcuts with new ids.
  - In total that is about 2× the sidecar and description writes plus 2× the shortcut operations, through the Drive token bucket.
  - `noteLanguage` (`PlaceNamer.swift:46-55`) has a smaller version of the same problem. Until display-language answers arrive, sidecars, descriptions and view folder names fall back to English, and they are rewritten or renamed a second time later.
- **Fix:** do not delete the old answers. Re-request the cells and overwrite them, and mark a cell dirty only when its answer changed. For a language change, wait until the display-language answer exists before changing names.

## Suggestion

- **S1. Metadata stages go quadratic when the token bucket is empty, and every dirty lookup scans the whole `kv` table.**
  - Where: `ViewStage.swift:63-83`, `DescriptionStage.swift:33-60` and `ViewExecutor.swift:39-45`.
  - After the bucket refuses, both loops keep promoting the whole sweep. Every asset stays dirty and in `seen`, so `pending(limit: N + seen.count)` reads a growing set.
  - `DirtyQueue.swift:41-46` uses `LIKE … ESCAPE` on `kv.key TEXT PRIMARY KEY`, which is case-insensitive and therefore not index-assisted, so each call scans all of `kv`. `kv` has more than N rows (`desc:` and `viewhold:` entries).
  - A rebuild or language change on 100k assets costs about 500 full scans per stage run, every round, until the shortcuts catch up (NFR-03).
  - Fix: break out on the first `retryLater` caused by the bucket, and use the range form `key >= 'dirty:view:' AND key < 'dirty:view;'`.
- **S2. A new sweep request does not restart a sweep that is already running.**
  - Where: `DirtyQueue.swift:54-58`.
  - Scenario: a sweep is cut off at cursor X (pause, quit or cancel), and then the owner renames a device group. Assets up to X were already processed with the old name and are skipped.
  - Fix: always reset the cursor to `""`.
- **S3. A day folder adopted in recovery is promoted without moves for other destinations.**
  - Where: `RecoveryWriter.swift:67-74` uses `DayStatRepository.promote`, not `DayFolderPromoter.promote`.
  - Scenario: NAS is recovered first with the day's files in the month folder, then Drive adopts the day folder. The NAS files are never moved, and "Sắp xếp lại" skips days that are already promoted.
- **S4. Renaming a Drive folder whose reserved id is not yet confirmed updates only the database.**
  - Where: `MoveWorker.swift:116-120`. If a crash had already created the folder under the old name, `confirmExisting` (`FolderEnsurer.swift:65-69`) or StartupRecovery accepts it, and the name stays wrong.
  - In `MoveRecovery.swift:81-96`, a crash between `start` and that DB-only commit gives `failed` plus a false "cần kiểm tra toàn vẹn" notice. The probe of the reserved id answers nil.
- **S5. Switching to country-only names does not refresh existing `en` entries.**
  - Where: `GeocodeScheduler.swift:118-135`. The `UPDATE` changes the `en` rows in place but does not call `markAssets(inCell:)`.
  - With display language `en`, sidecars, descriptions and the `byPlace` membership of those cells stay stale.
- **S6. With place names off, a Drive description that loses all its parts keeps its old `Place:`.**
  - Where: `DescriptionStage.swift:88-94`. A nil text returns `.unchanged`.
  - Case: GPS but no camera or lens. The FR-85 privacy toggle then does not take the place off Drive.
- **Already reported elsewhere, still open, confirmed from the engine side:**
  - Drive/photos I1 (geocode `noResult` stops all geocoding). `FakeGeocoder` returns `GeoPlace()` for unknown cells (`TestEnvironmentFakes.swift:152`), which hides the bug. The fix belongs in `GeocodeScheduler.swift:75-83`: cache an empty answer for that cell and locale.
  - Core S3 (`failed` shortcuts) and core S4 (`byPlace`-only filter for deleted and hidden assets).

## Verified sound
- **Promotion:** moves are queued in the same transaction for every `done` job (originals, edited, sidecars). Uploads in flight are caught by `UploadCompletion`. A NAS crash with a planned path is resolved with the real path and then moved.
- **Move and rename crashes (Drive and NAS):**
  - Probes cover both outcomes.
  - `rebasePaths` rewrites `upload_job.remote_id` and child folder ids.
  - Renames compare with the effective queued name, so no stacking.
  - The crash tests pass.
- **Root:** `FolderEnsurer` never creates the root. `startOver` runs only on the owner's choice, with the reserved id persisted first.
- **Geocoding privacy:** only `cell.center` is sent. With place names off, `runPass` returns before any request. `refreshAll` and `noteLanguage` make no network calls.
- **Sidecars:**
  - Content is per destination (that destination's jobs only).
  - An upload happens only when the hash changes, and sidecar completions do not mark the asset dirty, so there is no loop.
  - An album rename costs members × enabled sidecar types × destinations writes, as the spec requires.
- **Edit → revert → edit:** resource rows are never deleted. A revert keeps the edited file. A new adjustment hash bumps `content_gen`, and the same hash exports nothing.
- **Recovery:**
  - The three strategies run in spec order, with `h:` lookups through the hash index.
  - Look-alikes are settled by an export hash within a budget, and identical bytes are left alone.
  - Dedupe keeps one file per slot. The zero-match guard has a 0.5 ratio and also covers an empty destination that was expected to hold data.
  - The writer is idempotent, so a crash part-way through simply runs it again.
  - `paused(recovering)` blocks uploads. Unmatched files are never touched.
- **Reconciliation:** the token is taken before the pass. Rebuilt libraries re-attach through cloud ids. Gone assets only get `deleted_at`. Limited Photos access is refused (`allowsReading`).
- **Destructive calls:** `trashShortcut` checks the item type first. The engine trashes nothing except shortcuts.
- **Descriptions:** updates are gated by the recorded text.

## Unresolved questions
- C1: should "Kiểm tra ngay" refuse destinations that are paused for a root or folder problem, or only skip judging what sits under a trashed ancestor?
- I3: is "same Google account, several roots or Macs" a supported setup? If it is, the fake's list should match Drive's account-wide listing.

Status: DONE_WITH_CONCERNS
Summary: One Critical, a duplicate re-upload after an integrity check on a trashed root. Five Important: rebuild does not restore owner-deleted shortcuts, a stuck `trashPending` fails every cycle, other roots' shortcuts get trashed, a resumed session records the wrong parent, and a place refresh rewrites everything twice. Six suggestions. All 262 engine tests pass. Every finding comes from code tracing.
