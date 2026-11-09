# Review of the audit fixes, round 2

Scope: `6233118..b5699a0`. `git diff HEAD~6..HEAD` begins after `6233118`, so I1's commit was read separately.
Verification: `swift test --scratch-path .build-review2` (clean build directory): **811 tests in 135 suites passed, exit 0, 0 compiler warnings.** The `PhotoVault/` app target is not part of the package, so fix 3 (`AppModel+FirstStart.swift`) is neither compiled nor tested by this run.

## Status of I1–I6

| # | Verdict | Evidence |
|---|---|---|
| I1 untrash scope | Fixed | `RootProblemService.swift:114-122`: a candidate needs `listing.isUnder(root:)`. `DriveListing.isUnder` (`IntegrityDrive.swift:35`) walks trashed ancestors, which the listing now includes. When there is no root id, no listing candidates are taken. A test covers an old root and its child. |
| I2 restore atomicity | Fixed | `DatabaseBackup.swift:58-71`: the copy is verified, migrated, flagged, checkpointed (TRUNCATE), closed and flushed at `.restoring`. Only then is it swapped in, and `swapIn` rolls back the move-aside if it fails. Leftover `.restoring*` files from a crashed attempt are removed at the start of each candidate (`:59`). The failed `Store.open` in `AppEnvironment.openStore:182` has released its pool before the restore runs. The staging pool is closed explicitly, so there are no lingering in-process inode locks, and no WAL or SHM is carried onto the new file. A crash window remains (S1). |
| I3 onboarding NAS | Fixed (not compiled here) | `AppModel+FirstStart.swift:100-106` saves scope and rules for a kept NAS row. A changed folder always means a new `destinationId` (`AppModel+Destinations.swift:49`), so that case was already handled. A changed display name is still ignored (S3). |
| I4 stall vs progress | Partly | `ResourceRequestSession.swift:36` + `StalledRequestGuard.swift:100`: progress calls `touch()`, which is lock-protected. The closure only captures `@Sendable` values, so it is Sendable-safe. The other half of I4 was not done: a real stall is still `.transient` with a 60 s retry and no attempt counted (`ExportWorker.swift:269-272`), so it loops silently. Combined with Important 1 below, the owner is never told. |
| I5 last successful sync | Fixed for the AC hold; **regression introduced** | See Important 1. |
| I6 heal vs generation | Partly | `foundAgain` handles `targetGen` already raised before the file went missing. Edits made *while* the job is `missingRemote` are still lost (Important 2). `markHealed` is the only code that set `done` on a `missingRemote` job, and it now goes through `JobRepository.apply`. The `RecoveryVerifier` guard (`:91`) is correct. |

## Findings

### Important

**1. Export-side failures no longer block "last successful sync". This is a regression from 6f0cd60.** `Sources/PhotoVaultEngine/SyncCoordinator+Cycle.swift:220-224`
- Only `upload_job.last_error` is checked. Export failures write `resource.last_error` instead (`ResourceRepository.failExport`, `ExportWorker.swift:274-280`). Transient and destination-level export failures, including stalls, write nothing at all (`:269-272`).
- Scenario: "Optimize Mac Storage" is on and iCloud fails to deliver originals for days. The network is fine and Drive is `active`. Every cycle uploads 0 and no job has `last_error`, so `lastSuccessfulSyncAt` is set to now each cycle and `syncStalled` (FR-61, "không sync được > 24 giờ") never fires. Before this commit the pending backlog blocked it.
- Related, and older than this commit: an item-level upload failure defers a job after 9 attempts. With the 1 s→30 min backoff that takes about 10 minutes. The job then sits as `deferred` for 24 h, is retried, and is deferred again. Deferred jobs are excluded, so if every upload is rejected item-level, success is still recorded almost all the time. This contradicts the new doc comment at `:212-215` ("uploads that keep failing … do [count]").
- Fix: also count pending jobs whose resource has `export_attempts > 0` or `last_error IS NOT NULL`, and `deferred` jobs with `state_reason IN ('uploadFailures','exportFailures')`. Add a test where the export keeps failing. Whether a single deferred file should hold the notice back is a product call (Q1).

**2. A newer edit made while a file is `missingRemote` is still never uploaded after it is healed.** `Sources/PhotoVaultCore/Rules/JobTransitions.swift:266-267` (upsert) with `:195-202` (`foundAgain`) and `Sources/PhotoVaultEngine/IntegrityDrive.swift:135-136`
- `upsert` returns nil for `.missingRemote`, so `EligibilityService.recompute` drops the `targetGen` raise. Sidecars do the same: `SidecarPlanner.swift:83` returns early for `.missingRemote`.
- Scenario: A was uploaded at gen 1. The owner trashes its day folder, and `markBranchMissing` sets the job to `missingRemote`. The owner edits A in Photos, making gen 2, and the upsert is dropped. Then the owner presses "Khôi phục giúp tôi", which calls `healMissing` and then `foundAgain`. With `doneGen 1 == targetGen 1` the job becomes `done`. Gen 2 is never backed up and nothing reports it. `markHealed` marks only `[.view]` dirty, so a sidecar change is not re-planned either.
- Fix: let `upsert` apply `.contentChanged` to `.missingRemote` (line 174 already keeps the state unless it is `done`), so `foundAgain` sees `doneGen < targetGen`. In `markHealed`, mark the default channels (`[.sidecar, .view, .description]`), not just `.view`. Add a test that edits while missing and then heals.

### Suggestions

**S1. Crash window during the swap leaves no database, and the next launch starts as a fresh install.** `Sources/PhotoVaultStore/DatabaseBackup.swift:89-96`
- A crash or power loss after the main file is moved aside but before `.restoring` is renamed into place leaves `<db>` missing. The next `Store.open` (`AppEnvironment.swift:182`) creates an empty database, and the app goes to onboarding while a fully prepared `.restoring` sits unused.
- The window is small (a few renames), but it is the power-loss case this code exists for.
- Fix: at launch, if `<db>` is absent and `<db>.restoring` exists, finish the rename. Move `-wal` and `-shm` aside before the main file. `fsync` the directory after the swap.

**S2. `RecoveryVerifier` fills in a missing hash without the new state guard.** `Sources/PhotoVaultEngine/RecoveryVerifier.swift:84-87`
- The `expected == nil` branch writes `uploaded_hash` even if the job moved on (it was re-uploaded) during the async `sha256`. That overwrites the new upload's hash with the old file's hash, and the next verification would then flag a false mismatch.
- Fix: apply the same `state == .done` check, or add `AND state = 'done'` to the UPDATE.

**S3. Onboarding reconcile ignores a changed NAS display name, and the record it saves is a stale snapshot.** `PhotoVault/App/AppModel+FirstStart.swift:100-106`
- `displayName` is not compared or saved.
- `local` comes from the in-memory `localRecords` and is written back in full with `DestinationRepository.save`, which overwrites status, `recovery_required` and so on. Nothing runs before the baseline, so this is harmless today. A targeted update of scope, rules and name would be safer.

**S4. Progress callbacks reset the stall timer even when progress does not advance.** `Sources/PhotoVaultPhotos/ResourceRequestSession.swift:36`
- If PhotoKit keeps sending the same fraction while stuck, the stall guard never fires.
- Fix: touch only when the value increases. This is cheap and does not depend on undocumented PhotoKit cadence.

**S5. Stale `last_error` survives `retryDeferred`, `reinstate` and `retrySkipped`.** `JobTransitions.swift:140-165, 218-224`
- After the fix, a job that comes back to `pending` but is held by a rule (on battery, backfill only on AC power) keeps an old error. It then holds back "last successful sync" until it is tried again.
- Fix: clear `lastError` in these transitions, or accept this explicitly.

## Conclusion

No Critical findings. **Two Important findings remain**: one regression introduced by 6f0cd60 (Important 1) and one incomplete fix of I6 (Important 2). I4 is only partly addressed.

## Unresolved questions

- Q1: Should one file deferred for upload failures stop "last successful sync" (and so raise `syncStalled` after 24 h) while everything else is done, or should only a destination-wide failure count?
- Q2: The app target was not built in this review. Please confirm with `xcodebuild` that `AppModel+FirstStart.swift` compiles.

Status: DONE_WITH_CONCERNS
Summary: I1–I3 are fixed. I4 and I6 are only partly fixed. The I5 fix brings a new gap: export failures and deferred failures no longer hold back "last successful sync". Tests: 811/811 pass on a clean build.
