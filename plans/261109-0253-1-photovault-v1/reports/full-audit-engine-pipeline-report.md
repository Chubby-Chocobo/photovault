# Full audit: engine pipeline

Scope: every in-scope file in `Sources/PhotoVaultEngine` (EngineEnvironment, SyncCoordinator(+Cycle), ExclusiveLane, Baseline, Scanner, ChangeTracker, EligibilityService, ClassifyWorker, PlacementAllocator/AssetFinalizer, ResourceGuard, StagingManager, ExportWorker, UploadRunner, UploadAttempt(+Errors), UploadCompletion/LayoutResolver, FolderEnsurer, StartupRecovery, InstanceLock, ContainerLocator, EngineQueries, DestinationHealth, ActivityLog). I followed callees into Core (`JobTransitions`, `Eligibility`, `ErrorClassifier`, `TokenBucket`), Store and the PhotoKit adapter where a finding depended on them. Branch `review/full-codebase-audit` at `451f1c3`. Findings already fixed in earlier rounds are left out.

Checks I ran:
- `swift test --scratch-path .build-main --filter PhotoVaultEngineTests`: 262 tests in 39 suites passed.
- Probe tests in a scratch copy of the repo (`/private/tmp/claude-501/-Users-annh-workspace-photovault/c95079e8-f124-4c29-8253-08dccc3843e6/scratchpad/pv/Tests/PhotoVaultEngineTests/ZZAudit*.swift`). No file in the worktree was changed. Their results are quoted under each finding.

## Critical

None found. I did not find any path that duplicates a file or deletes or overwrites owner data. The closest is I4, where a photo is never backed up.

## Important

### I1. If Photos access is lost during an export pass, the pass spins forever

- **Where:**
  - `ExportWorker.swift:249-250`: `.destinationLevel` (and `.transient`/`.verify`) only resets the row to `none`, with no `next_export_attempt_at`.
  - `ExportWorker.swift:83-84`: a failed id leaves `inFlight` but is never added to `held`.
  - `ExportWorker.swift:123-126`: when the queue runs dry it is fetched again, excluding only `inFlight ∪ held`.
  - `ErrorClassifier.swift:49`: `notAuthorized` and `libraryUnavailable` are classified as `.destinationLevel`.
- **Scenario:**
  1. The owner revokes Photos access, or the library's disk goes away, while new photos (incremental, not rate-limited) wait to be exported.
  2. Each export fails at once with `notAuthorized` and is reset to `none`.
  3. The candidate query returns the same rows again, and the loop never ends.
- **Measured:** 5 incremental candidates gave 3,440 export attempts in 2 s, each with its own DB write.
- **Consequences:**
  - The cycle never reaches a pass boundary, so every owner command waiting on the lane hangs.
  - "Pause all" has no effect, because `mayStartUpload` gates only uploads.
  - Backfill candidates drain the backfill bucket before they are held, so backfill is throttled for about an hour after access comes back.
  - The same loop happens for `PhotosSourceError.cancelled` without a permit reason (`ExportWorker.swift:236-238`; PHPhotosError 3072, or a writer `.stopped`).
- **Fix:**
  - Keep a per-pass `failed` set and exclude it from the refetch.
  - On a Photos `.destinationLevel` error, end the pass (`blockedBy`) and let the cycle re-check `authorizationStatus()` at the next boundary.
  - Give `transient`/`verify` a short `next_export_attempt_at`.

### I2. `ClassifyWorker.runPass` is quadratic in the provisional assets it skips; in newOnly/since mode those assets never leave

- **Where:**
  - `ClassifyWorker.swift:44-61`: `want = classifyBatchSize + seen.count`, so every query returns everything seen so far.
  - `ClassifyWorker.swift:88, 95`: `loadWork == nil` and a rate-limited denial both return `.skipped` and keep the asset provisional.
  - `EngineQueries.swift:19-24`: no index on `category_provisional`; there is a full sort every call.
- **Scenario:**
  - The default `photosWithoutCameraExifAreSaved = true` makes every non-screenshot, non-RAW image provisional after the scan (`CategoryClassifier.swift:32-33`).
  - With a newOnly destination (or a recent `since` day), pre-baseline images fail `needsClassification`. They stay provisional forever and are walked again in every round of every cycle.
  - In full mode the same happens during the first backfill, once the bucket denies header reads (`rateLimited: insertedAt == nil`). Each skipped asset also costs one `admit`, which includes a `SUM` query over staging.
- **Measured** (batch 25, in-memory DB, fake Photos):

  | Provisional assets | One pass |
  |---|---|
  | 4,000 | 1.12 s |
  | 8,000 | 2.61 s |
  | 16,000 | 8.52 s |

  A quadratic fit gives about 20 minutes per pass at 200k. Every new photo waits behind that pass, and an idle timer cycle burns the same CPU (NFR-03, NFR-08).
- **Fix:**
  - Use keyset pagination: a cursor on `(inserted_at IS NULL, creation_date, asset_key)`.
  - Stop the pass at the first `.rateLimited` denial for non-incremental work.
  - Skip the query entirely when no destination could need classification.

### I3. A deleted asset with any job already done leaves its other jobs `pending` forever

- **Where:**
  - `EligibilityService.swift:43-49`: a deleted asset calls `JobRepository.cancelAll`.
  - `JobTransitions.swift:255-256`: that is all-or-nothing, and cancels nothing if any job is `done` or `uploading`.
  - `EngineQueries.swift:144`: `exportCandidates` excludes `deleted_at IS NOT NULL`.
- **Scenario:** A Live Photo's `photo` is uploaded and its `pairedVideo` is still pending. The owner deletes the asset in Photos.
- **Probe result:** after three cycles over nine days the states are still `["pairedVideo=pending", "photo=done"]`, the snapshot shows `pending=1`, and backfill is `0/1`.
- **Consequences:**
  - The menu bar never reaches 0 pending.
  - Backfill never reaches 100%.
  - Deferred jobs of such an asset cycle through `retryDeferred` forever.
- **Not consistent with the code's own comment:** `EligibilityService.swift:41-42` says "jobs that never uploaded anything are cancelled". That is a per-job rule; the code does all-or-nothing.
- **Fix:** For `deletedAt != nil`, apply `.cancel` to each `pending`/`deferred` job. Keep `done` and `uploading` jobs, as the spec says (`eligible = deleted_at IS NULL`).

### I4. Wall-clock comparisons decide newOnly eligibility, so a backward clock step hides new photos for good

- **Where:**
  - `Baseline.swift:22,30` and `DestinationRepository.add` store `baselineAt = now`.
  - `ChangeTracker.swift:83` stamps `insertedAt: context.now`, the processing time.
  - `Eligibility.swift:7-8` compares `inserted >= baseline`.
- **Scenario:** The Mac's clock is a few minutes fast when the owner presses Start. NTP then corrects it backwards. Photos taken in that window get `insertedAt < baselineAt`, so a newOnly destination never plans them. Nothing is surfaced to the owner.
- **Probe result:** clock stepped back 120 s, new photo added, two cycles: `jobs=[]`, 0 files.
- **A forward step does damage too:**
  - `DeferredJobSweeper.swift:16` skips every deferred job for good once `now - deferredSince > 30 days`.
  - `TokenBucket.swift:77` (`lastUpdate = max(last, date)`) stalls backfill until real time catches up.
  - `expireIdle` releases every staged file.
- **Fix:**
  - An insert replayed from the change history is after the baseline by construction. Stamp `insertedAt = max(now, max(baselineAt))`, or compare a monotonic sequence counter kept in `kv`.
  - Clamp elapsed-time checks against a stored "last seen now".

### I5. The snapshot query costs about 0.6 s and the app runs it every 10 s, even when idle

- **Where:**
  - `SnapshotBuilder.swift:17-30` runs `jobCounts` once per destination and once more for totals. The `(? IS NULL OR destination_id = ?)` filter defeats the `(state, destination_id)` index.
  - `backfillProgress` runs two `COUNT(DISTINCT)` passes, and `uploadedBytes` joins every done job (`EngineQueries.swift:182-221`).
  - The caller is `AppModel.swift:168-174`, which polls every 10 s whatever the engine is doing.
- **Measured:** 200k assets × 2 resources × 2 destinations (800k jobs), file DB: 0.576, 0.578 and 0.586 s per read. That is about 6% of a core spent forever on an idle machine (NFR-03: "Idle: CPU ≈ 0"). Each read also competes with the cycle's reads.
- **Fix:**
  - Use one `GROUP BY destination_id, state` query.
  - Keep `uploadedBytes` and backfill counters incrementally, updated in the same transactions as the job changes.
  - Poll only while `overall == .syncing`.

### I6. Refreshing a file the owner deleted at the destination ends in deferred, then skipped, and never reaches "missing"

- **Where:**
  - `UploadAttempt.swift:252-253`: a refresh with `doneGen > 0` calls `replaceContent(remoteId:)`.
  - `ErrorClassifier.swift:40`: `.notFound` is item-level.
  - `UploadAttempt+Errors.swift:55-56` turns that into `itemFailure`.
- **Scenario:**
  1. The owner deletes a backed-up photo on Drive, then edits the photo in Photos.
  2. The refresh gets a 404 eight times, then becomes `deferred(uploadFailures)`, and after 30 days `skipped(deferredTooLong)`.
  3. The job never becomes `done`, so the integrity check (which only marks `done → missingRemote`) cannot surface it. The FR-47 confirm-and-reupload prompt never appears, and the edit is never backed up.
- **Fix:** In a refresh, treat `notFound` from `replaceContent` as `missingAtDestination`. That needs a transition from `uploading` or `pending` with `doneGen > 0`. Then let the owner confirm.

## Suggestion

### S7. Every album change rebuilds album membership for the whole library inside the change transaction

- **Where:** `ChangeTracker.swift:70, 113-133`.
- **What happens:**
  - Each change with `albumsChanged` calls `photos.albums()`, which enumerates every album and every member.
  - It then loads `localIdIndex` (all assets) and runs one `AssetRepository.albums` query per asset that has a membership. All of this holds the writer.
  - At 200k assets that is roughly 100k queries per change. A replay of N album edits pays it N times.
- **Fix:** Fetch the album list once per `process()` call and diff in memory with a single `album_member` read.

### S8. The scanner's album index is kept for the whole session

- **Where:** `Scanner.swift:17, 64-71`.
- **What happens:** The `[localId: [Membership]]` map for the full library stays in memory after the scan completes. At 200k members I estimate 30–40 MB, against the 100 MB idle budget (NFR-03).
- **Fix:** Set `albumIndex = nil` when `runBatch` returns `.complete`.

### S9. `FolderGone.markBranchMissing` loads every done job of the destination into memory, inside a write

- **Where:** `RootProblemService.swift:137-141`, called from `UploadAttempt+Errors.swift:50`.
- **What happens:** That can be 400k structs at 200k assets, on every `folderMissing`, and the in-flight upload in the same folder repeats it.
- **Fix:** Filter in SQL on `remote_logical_parent = ? OR remote_logical_parent LIKE ? || '/%'`.

### S10. Staging releases are linear scans

- **Where:**
  - `StagingManager.swift:70-78`.
  - `UploadAttempt.swift:58`, which runs after every `.done`.
- **What happens:**
  - `releaseUnneeded(asset:)` fetches every `ready` resource (`limit: Int.max`) and then filters by asset in Swift.
  - The per-round sweep also opens one write transaction per ready resource.
- **Fix:** Add a keyed fetch for one asset.

### S11. The ETA baseline is set once and never reset

- **Where:** `SyncCoordinator.swift:189-197`.
- **What happens:** After the app has been idle for weeks, adding a destination yields an ETA computed over weeks of elapsed time.
- **Fix:** Reset `backfillObservation` when backfill finishes (`done == total`) or when `total` grows.

### S12. `EngineQueries.apply` swallows every error, not only invalid transitions

- **Where:** `EngineQueries.swift:172` (`try?`).
- **What happens:** A real SQLite error, such as disk full, lets the surrounding transaction commit partially. For example, `.tooLargeForDisk` or `.exportGaveUp` reaches only some destinations' jobs.
- **Fix:** Catch only `JobTransitionError`.

### S13. `SettingsStore` drops errors and updates

- **Where:**
  - `SettingsStore.swift:23`: `try? JSONDecoder().decode`.
  - `SettingsStore.swift:38-45`: `update()` reads `settings` before its `await` and writes it after.
- **Decoding:**
  - `GlobalSettings` uses synthesized `Codable`, so a key added in the next release makes the stored JSON undecodable.
  - That silently resets the owner's choices to the defaults. For example, `includeVideos` turned off comes back on and videos start uploading, and a changed `dayFolderThreshold` is lost.
- **Lost update:**
  - Probe result: two concurrent `update` calls (`includeVideos=false`, `includeHidden=true`) end with `includeVideos=true`, so the first update is lost.
  - Today's only caller replaces the whole value, which hides this.
- **Fix:**
  - Use `decodeIfPresent` with defaults, and surface a decode failure.
  - In `update()`, assign `settings = next` before the `await`.

### S14. Step 1 checks destinations one at a time, with no timeout

- **Where:** `DestinationHealth.swift:12-27` and `StartupRecovery.swift:61-63`.
- **What happens:** A NAS whose SMB mount hangs (stat calls blocking for tens of seconds) delays the Drive uploads of every cycle by that much, for as long as the NAS stays half-gone. I did not reproduce this on a real share.
- **Fix:** Run the checks concurrently, with a deadline per destination.

## Verified sound

- **Lane:**
  - `run` checks and sets `running` with no `await` in between.
  - `ExclusiveLane` has no lost wake-up.
  - A waiting command stops new uploads (`mayStartUpload`) and gets the lane at the next boundary.
  - No in-process `uploading` job exists when `resolveInterrupted` runs at the start of a cycle. `runCancellable` awaits the inner task.
- **Crash at every await in `UploadAttempt`, `FolderEnsurer` and `StartupRecovery`:**
  - Reserved file and folder ids are persisted before the create call. `.reserved` never overwrites an id.
  - `alreadyExists` leads to a probe, then `settle` or replace on the same id.
  - Path-addressed jobs save the planned path and SHA-256 in `upload_intent` together with `startUpload`. Recovery accepts the intent hash.
  - Local conflict names are deterministic by hash, so a retry does not duplicate.
  - `synchronous=FULL` and `fullfsync` are on.
- **Edits:**
  - Three quick edits move `content_gen` forward only.
  - `uploadSucceeded` with `doneGen < targetGen` goes back to `pending(refresh)`.
  - Stale staging is released because `jobsNeedingStaging` requires `target_gen <= staging_gen`.
  - A session is dropped when its MD5 differs from the content.
- **Disk:**
  - Every export and header read goes through `ResourceGuard`, which takes no `await` between its decision and registering the permit.
  - The checkpoint cancels at the critical watermark, and partial files are removed.
  - The too-large flag sits on the resource and is re-applied to new pending jobs.
- **Cancellation:**
  - PhotoKit maps `CancellationError` to `.cancelled`, so a cancelled export resets its row.
  - `EngineAbort` is rethrown untouched everywhere.
- **First baseline:**
  - The token is taken before the scan.
  - Assets inserted during the scan are stamped by the history replay (`stampInsertedOnExisting`).
  - The offset cursor falls back to localId, then to date.
- **Two destinations, one offline:**
  - Exports and staging are only for `active` destinations.
  - Uploading jobs of the offline one stay `.later` and are re-probed each cycle.
  - `signedOut`, `userPaused`, `recovering` and `folderTrashed` survive health checks.
- **Other:**
  - `InstanceLock` uses `flock` with `O_CLOEXEC`.
  - `ContainerLocator` refuses unsandboxed runs without `--dev-container`.
- **Logs:**
  - No file names, coordinates, tokens or session URIs in log calls.
  - `DestinationError` descriptions carry no paths.
  - The classify log prints a `PhotosSourceError` that may include an opaque `localId`, but no file name.

## Unresolved questions

1. Deleted assets (I3): should the remaining jobs be cancelled, or should the parts already staged still be uploaded? The spec's `eligible = deleted_at IS NULL` suggests cancelling.
2. NewOnly: should iCloud-synced arrivals of old photos (inserts in the history after Start) count as "new"? Today they do.

Status: DONE_WITH_CONCERNS
Summary: No Critical findings. Six Important findings: an export pass that spins forever when Photos access is lost (I1), a quadratic classify pass that makes large newOnly libraries crawl (I2), deleted assets with jobs stuck pending (I3), newOnly depending on the wall clock (I4), a snapshot poll that costs about 0.6 s every 10 s (I5), and refreshes of deleted remote files that never become "missing" (I6). I1–I5 were reproduced with probe tests in a scratch copy; I6 is from reading the code only.
