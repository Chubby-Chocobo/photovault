# Review of the audit-fix commits (origin/release/0.1.0..HEAD, 20 commits)

## Verification run

- `swift test --scratch-path .build-review`: exit 0, 806 tests in 135 suites passed.
- `xcodebuild … CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedDataReview`: BUILD SUCCEEDED, exit 0.
- Randomized probe of the v3 triggers (Python sqlite3, the trigger SQL copied by hand, 20k random inserts, updates, bulk updates, per-destination deletes, seeded from existing rows): `job_count` and `backfill_asset` always equal a fresh `COUNT(*)` / `COUNT(DISTINCT)`, and no count ever went negative. `uploaded_bytes` is exact unless a resource's `size_bytes` changes while its job stays `done` (see S1).

## Verdict per commit

| Commit | Fixed? | Note |
|---|---|---|
| a6f1894 name prefix in code points | yes | `substr(…, length(?))` measures both sides in code points |
| 2ecc32c stall guard | partly | exactly-once resume is correct and late chunks hit an aborted writer (no write). Activity = data chunks only (I4) |
| b941124 unnamed places / offline library | yes | |
| 1c12f6a account picker, 403s, cancellation | yes | |
| e1eec1d 30-day window reset | yes | every `retryDeferred`/`reinstate` caller checked |
| 55bebee DB restore at launch | partly | I2 |
| d3b02f7 savable settings | yes | `SettingsStore.update` is serialized, has no deadlock and loses no write. Tolerant decode is safe: `GlobalSettings` has no optional fields |
| fdcc936 sign in again, 15-min disk timer, idle poll | yes | `running = true` and then `publish()` happen before the cycle body, so polling resumes when a cycle starts. Minor latency in S3 |
| 61bf22a onboarding reconcile | partly | the baseline gate is sound: no cycle runs before `beginBaseline`, and `goLive` runs after it. The NAS branch is incomplete (I3) |
| a689fe6 snooze keys, start while recovery waits | yes | |
| a616850 local fd / flush / readdir | yes | no fd leak. `O_NONBLOCK` has no effect on reads of regular files (local or smbfs). The walk is cancelled through a flag (S4) |
| 9e73c26 Photos away + large-library cost | yes | classify cursor: strict seek, each pass restarts from nil. An asset that moves mid-pass is picked up next pass and never starved. Counters verified (above) |
| bcd07b0 trashed root, view repair | yes | the heal path has a generation hole (I6) |
| 13e5aeb resumed-upload parent + gone replace | yes | `landedParent`, and the move is queued in `UploadCompletion.commit`. Works with I6 to cause the hole |
| 096de2b disk-full stamp, "successful sync" | partly | I5 |
| 3b4c71d Drive list includes trashed | regression | I1. Every other `list(under:)` caller filters trashed items correctly: IntegrityDrive, RemoteInventory (`isUnderRoot` stops at trashed), RecoveryTriggers, RecoveryService walk, ViewRebuildPreparation |
| f7c147e backup files only under current root | yes | |
| e155a9b, 5b584e2, 83bc784 | n/a | CI, test, docs |

## Findings

### Important

**I1. "Khôi phục giúp tôi" now untrashes every trashed PhotoVault folder in the account, including other roots.** `Sources/PhotoVaultEngine/RootProblemService.swift:112-120`
- Before 3b4c71d, the listing excluded trashed items, so this loop was dead code. Now `list(under: nil)` covers the whole account (drive.file scope, every root this client created) and includes trashed items. Drive also marks every descendant of a trashed folder as `trashed`.
- Scenario: the owner moved to root "Camera Uploads 2" and trashed the old "Camera Uploads". Later a day folder of the current root is trashed and the owner presses "Khôi phục giúp tôi". The old root (a schema-tagged folder) and every one of its descendant folders are probed and untrashed, one API call each. This undoes a deliberate owner action outside this destination.
- Fix: keep only candidates where `DriveListing.isUnder(root: rootId, item)` holds, walking through trashed ancestors, which are listed now. Or drop the listing and rely on `RemoteFolderRepository … created`.

**I2. `restoreNewest` is not atomic; a mid-way failure leaves an empty or unflagged database for the next launch.** `Sources/PhotoVaultStore/DatabaseBackup.swift:60-71`
- (a) `copyItem` (`:64`) or the roll-back `moveItem` (`:71`) can throw, for example on a full disk, which is common when SQLite corrupts. Nothing moves the `.corrupt-*` files back. On the next launch `Store.open` finds no file, creates an empty database and the app goes to onboarding. All job state is silently gone (the damaged files and backups still exist on disk).
- (b) If `markAllRecoveryRequired` (`:66`) throws, the restored backup stays in place without `recovery_required`. The next launch opens it as healthy, so files uploaded after the backup are pending again and uploaded a second time (breaks NFR-01, no duplicates).
- Fix: verify and set the recovery flag on the copy at a temp path, then rename it into place. Wrap everything after the move-aside in `do/catch` that restores `movedAside`.

**I3. Onboarding reconcile ignores changed NAS answers after an unfinished start.** `PhotoVault/App/AppModel+FirstStart.swift:100` and `:51`
- `PendingLocalDestination.destinationId` stays the same while the owner edits scope, rules or name in `LocalDestinationForm`. The row is therefore kept (`local.id == plan.nas?.destinationId`), and `commit(nas)` is skipped because a row with that id exists.
- Scenario: start fails at "scan stalled". The owner switches the NAS from "new only" to "full" and presses Start again. The NAS still backs up new photos only, and the existing library is never copied there.
- The Drive branch updates `scope` (`:88`); the local branch has no equivalent. Fix: compare scope, rules and name and save the record, or remove and re-commit it.

**I4. The stall guard counts only data chunks, not download progress.** `Sources/PhotoVaultPhotos/StalledRequestGuard.swift:83,96` and `ResourceRequestSession.swift:34`
- Research item 3 left this unverified: whether `requestData` streams iCloud-only originals or downloads them fully before the first chunk. If it downloads first, a multi-GB iCloud-only video that takes more than 15 minutes is cancelled every time.
- It then fails as `.transient` with a 60 s retry (`ExportWorker.transientRetryDelay`), which consumes no attempts. The result is an endless download loop: the asset is never backed up and the owner is never told.
- Fix: set `options.progressHandler` and call `touch()` from it, and/or count stalls toward the export attempts.

**I5. "Last successful sync" now fails during the default AC-power hold, which triggers a false "không sync được > 24 giờ".** `Sources/PhotoVaultEngine/SyncCoordinator+Cycle.swift:218-223`
- `backfillOnlyOnACPower = true` is the default. On battery, `ResourceGuard` denies backfill exports (`ResourceGuard.swift:95,106`), so cycles upload 0 while backfill jobs stay `pending`. `waiting > 0`, so no success is recorded.
- `NotificationPolicy` only excludes a global pause, so a MacBook on battery for a day during the initial backlog raises `syncStalled`. The same happens with Low Power Mode, thermal holds and the expensive-network hold.
- Fix: count only pending jobs that could run now (not held by a policy the owner set), or treat cycles with `uploadsHeld` or a policy block as neutral. Read `job_count` instead of scanning `upload_job`.

**I6. Healing a `missingRemote` job bypasses the generation check, so a newer edit is never uploaded.** `Sources/PhotoVaultEngine/IntegrityDrive.swift:133`, with `JobTransitions.swift:183`
- The new transition `pending/uploading → missingRemote` (replace returned 404) leaves `targetGen > doneGen`. If the file later shows as present (a transient 404, or the owner restoring the file followed by `healMissing` or the next check), the raw `UPDATE … SET state = 'done'` marks it done at the old generation.
- `upsert` will not raise `targetGen` again (it is unchanged), so the edited version is never backed up and nothing reports it. Trigger is uncommon on Drive, but the result is silent.
- Fix: in `markHealed`, set `state = CASE WHEN done_gen < target_gen THEN 'pending' ELSE 'done' END` (with `origin = 'refresh'`), or go through a `JobTransitions` event.

### Suggestions

**S1. `uploaded_bytes` undercounts recovered files permanently.** `Sources/PhotoVaultEngine/RecoveryWriter.swift:162-166`
- `JobRepository.save` (the trigger records `bytes` from `resource.size_bytes`, which is NULL, so 0) runs before `UPDATE resource SET size_bytes …`. The counter never catches up while the job stays done (the probe confirms this).
- Fix: move the size update above the save.

**S2. `RecoveryVerifier.settle` can now mark a refreshing job `missingRemote`.** `Sources/PhotoVaultEngine/RecoveryVerifier.swift:90`
- Before, `pending`/`uploading → missingAtDestination` threw and the snapshot was ignored. Now it succeeds, while `settle` never re-checks that the job is still `done` with the same `remote_id`/hash it hashed.
- Fix: add the same "unchanged" guard that `markMissing` uses.

**S3. Idle UI refresh now depends on cycles.** `PhotoVault/App/AppModel.swift:180`
- `macFreeBytes`, `diskState` and `evaluateNotifications()` refresh only when a cycle publishes, which is hourly when idle. The disk-critical card and the 15-minute `needsDiskRecheck` (`:165`) can lag up to 60 minutes after the disk fills while idle.
- Fix: refresh the disk figure in the 15-minute timer, or keep a cheap idle poll of the disk only.

**S4. `flush` ignores directory fsync errors.** `Sources/PhotoVaultLocal/DirectoryHandle.swift:145-147`
- The new `flush` call sites promise "survives power loss before success is reported", but `sync()` discards both `F_FULLFSYNC` and `fsync` errors. On smbfs both commonly fail with ENOTSUP. At least log once per volume, so the durability claim is not silently false.

## Bottom line

No Critical findings. Six Important findings remain (I1–I6). I1 is a regression introduced by 3b4c71d; I2 and I3 are incomplete fixes; I4–I6 are gaps in, or side effects of, the new behavior. The v3/v4 migrations, the trigger arithmetic, the classify cursor, deleted-asset cancellation, newOnly stamping, `SettingsStore` serialization, the onboarding baseline gate and the exactly-once resume in `StalledRequestGuard` are correct.

## Unresolved questions

- Does `PHAssetResourceManager.requestData` deliver chunks while an iCloud original downloads? This decides whether I4 is real or theoretical (research item 3, still open).
- Product intent for FR-61: should owner-configured holds (AC power, expensive network) count as "không sync được"?
