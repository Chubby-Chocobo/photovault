# Code review: engine and store data safety

Scope: `Sources/PhotoVaultEngine/**` and `Sources/PhotoVaultStore/**`, plus the Core rule files `JobTransitions`, `Eligibility` and `ResourcePlanner`. Diff `7cad755..HEAD` on `feat/photovault-v1`. I read the code and traced each scenario by hand. I did not run any tests.

## Critical

### C1. "Check now" during a sync marks files as missing that are not; confirming the re-upload duplicates them on Drive

- **Where:** `IntegrityChecker.swift:111-127`, `SyncCoordinator+Hardening.swift:23`, `JobTransitions.swift:167-176`.
- **What happens:**
  - `checkDrive` lists the whole root first. Only after that does it read `doneJobs(id)`.
  - `runIntegrityCheck` is an ordinary method on the coordinator actor, and actors are reentrant. The app calls it straight from the UI (`AppModel+Hardening.swift:32`), so it runs while a backfill cycle is suspended mid-upload.
  - A job that finishes between the listing and the `doneJobs` read has a `remoteId` that is not in `items`. `isGone` returns true and the job is set to `missingRemote`.
  - The owner is then told "N files missing". Confirming applies `reuploadConfirmed`, which clears `remoteId`, so a new id is reserved and a second file is created next to the original.
  - The same race affects views. Shortcuts created during the listing are flagged `userRemoved` (lines 160-169) and are never recreated.
  - On a local destination, a concurrent `MoveWorker` move after the snapshot causes the same false alarm (`IntegrityLocal.swift:15-24`). The re-upload there is idempotent by name and hash, so it does not duplicate.
- **Fix:**
  - Run owner integrity checks through the cycle's single-flight path, or take a per-destination lock shared with `UploadRunner` and `MoveWorker`.
  - Read `doneJobs` *before* the listing, and treat any job whose `updatedAt` is after the listing started as not checked.

### C2. Local/NAS destination: a crash between writing the file and saving its path gives a duplicate or a wrong permanent skip

- **Where:** `UploadAttempt.swift:97-105, 145-147`, `StartupRecovery.swift:70-75`, `LocalFileOps+Write.swift:40-52, 76-83`.
- **What happens:**
  - The local destination has `reservesIds=false`, so `job.remoteId` (the path) is saved only after `upload` returns (line 146).
  - After a crash in that window, `resolve()` sees `remoteId == nil` and simply requeues the job, on the assumption that "path-addressed upload is idempotent".
  - That is only true if the path and content are unchanged. The retry recomputes `LayoutResolver.plan`:
    - **(a) The day folder changes.** Today's day is promoted when the N-th photo of the day arrives, so the retry writes into the new day folder. The first copy in the month folder is orphaned: a duplicate no job or move ever tracks.
    - **(b) An edited resource changes.** If it was re-edited before the retry, its hash differs. `inspect` then returns `.different`, and because `kind != .original` the upload throws `foreignFile`. That is a permanent skip, so the edit is never delivered.
    - **(c) A refresh is interrupted.** For a refresh crashed after the replace, `uploadedHash` is stale. A further edit then makes `replace` throw `foreignModified`, also a permanent skip.
- **Fix:** For path-addressed destinations, save the planned `parent/name` (for example as `remoteId` plus `remoteLogicalParent`) in the same transaction as `startUpload`. `resolve()` should probe it, and the retry should reuse it rather than recompute the layout; `MoveWorker` relocates the file afterwards.

## Important

### I3. Pause, the network and power rules, and change tracking are checked only when a cycle starts, and one cycle can last for hours

- **Where:** `SyncCoordinator.swift:169, 197-200, 233-258`, `UploadRunner.swift:86-118`, `EngineEnvironment.swift:51`.
- **What happens:**
  - `globallyPaused` is checked only in `runGuarded`.
  - `uploadsAllowed` (expensive network, AC power) is computed once per cycle.
  - `runDestination` reads the destination's status once and then keeps refilling its buffer from `readyToUpload`. That query does not filter on destination status.
  - With `maxCycleIterations = 100_000` and a 20 GiB/h backfill bucket, a backfill cycle runs for hours. During that time:
    - "Pause all" and pausing one destination have no effect.
    - Tethering to a phone (an expensive network) keeps uploading over it.
    - New photos are not scanned, because `tracker.process()` runs only at the start of the cycle.
- **Related problem:** Owner commands also run interleaved with the cycle. For example, `changeDriveRoot` → `resetState` deletes the jobs while an upload is in flight. `UploadCompletion.commit` then throws `StoreError.notFound`, which `applyIfValid` does not catch. That error cancels every destination's task group mid-transfer and fails the cycle.
- **Fix:**
  - Re-check pause, `uploadsAllowed` and `acceptsUploads` before every dispatch in `runDestination`.
  - Bound a cycle's length, for example by returning to step 1 after K rounds.
  - Serialize owner commands that change jobs with the cycle.

### I4. Sidecar staging files are shared across destinations

- **Where:** `SidecarDelivery.swift:29-43`, `SidecarPlanner.swift:16-23`, `UploadRunner.swift:73-76`.
- **What happens:**
  - The path is `fileURL(assetKey, type, generation: targetGen)`, which has no destination in it. Destinations upload in parallel.
  - The content differs per destination: `backupName` and `state` come from that destination's jobs.
  - Destination B overwrites A's file (`.atomic` write), and A's `staging.remove(url)` deletes B's file without any lease check. Drive reads the file again for each chunk (`.fileRange`).
  - Results: sends fail with "file not found" (counted as item failures), or the wrong destination's bytes are sent. A checksum mismatch follows, and after more than 3 mismatches the sidecar is skipped.
  - This is very likely with Drive and a NAS configured together, because both sidecar jobs become ready in the same pass.
- **Fix:** Put the destination id in the sidecar staging path, or write to a unique temp file per attempt.

### I5. A stale resumable session is reused for different content and never dropped

- **Where:** `UploadAttempt.swift:197-204`, `JobTransitions.swift:103-129`.
- **What happens:**
  - Resume is attempted whenever `sessionRef` and `sessionMd5` are set. Nothing compares `job.sessionMd5` with `request.content.md5` or checks the size.
  - The session is cleared only on `uploadSucceeded` and `reuploadConfirmed`. The `itemFailure`, `stagingLost`, `destinationFailure`, `retryDeferred` and `retrySkipped` transitions all keep it.
  - Scenario: a large video upload is interrupted (quit or transient errors), then the video is trimmed (generation 2, new size). Every later attempt resumes the generation-1 session with generation-2 bytes.
  - Drive answers with something other than 404/410 (size mismatch, so `itemRejected`, an item-level error). The job loops: 8 attempts, deferred, after 30 days skipped. `retrySkipped` keeps the same session, so it fails the same way.
- **Fix:**
  - Resume only when `sessionMd5 == request.content.md5`; otherwise clear the session and open a new one for the same reserved id.
  - Clear the session on `stagingLost` and on an item failure that happens during resume.

### I6. Database writes made before a side effect are not durable across power loss or a kernel panic

- **Where:** `Store.swift:27-29`.
- **What happens:**
  - The pool runs WAL with `PRAGMA synchronous = NORMAL` and no `fullfsync`. In that mode SQLite can roll back committed transactions after a system crash; on macOS, plain `fsync` does not reach the disk either.
  - A reserved file or folder id is committed (`UploadAttempt.swift:102`, `FolderEnsurer.swift:54`) and then the create call succeeds. A power loss then drops the reservation, and the next run reserves a new id, so a duplicate file or folder appears.
  - This breaks NFR-01's "crash at any time", which the local writer itself honours with `F_FULLFSYNC`.
- **Fix:** Use `synchronous = FULL` plus `PRAGMA fullfsync = ON` (and `checkpoint_fullfsync`), at least for the write-ahead-of-side-effect transactions.

### I7. Jobs created after a resource is marked too large for the disk stay `pending` forever, with nothing shown to the owner

- **Where:** `ExportWorker.swift:229-231, 279-288`, `EngineQueries.swift:142`, `RootProblemService.swift:161-172`, `DiskGuardPolicy.swift:112-114`.
- **What happens:**
  - `tooLargeForDisk` is applied only to jobs that are `pending` when the export is cancelled.
  - `exportCandidates` excludes `too_large_for_disk = 1` resources.
  - `revisitTooLarge` needs `sizeBytes`, which stays nil because the export never finished.
  - `retryDeferred` clears the flag only by going through `deferred` jobs.
  - Scenario: a destination added later, or a rule widened, adds a pending job for that video after the first destination's job was cancelled or the destination removed. The new job is never exported, never deferred, and never surfaced.
- **Fix:** When a job is upserted for a resource that is `too_large_for_disk`, apply `.tooLargeForDisk` to it. Also let `retryDeferred` clear the flag for resources that have no deferred job.

## Minor

### M8. The view rebuild treats a failed probe as "folder gone" and creates duplicate view folders

- **Where:** `ViewStage.swift:146-149`.
- **What happens:** `try? probe` turns a 429/5xx response or an offline error into `nil`, so the folder is invalidated. `ensure` then reserves a new id and creates a second view folder next to the existing one, which still holds its shortcuts.
- **Fix:** Only a `nil` result (not found) or `trashed` should invalidate. Rethrow `DestinationError` from the probe.

### M9. The staging release checks the lease before an `await` and deletes after it

- **Where:** `StagingManager.swift:52-56, 75-79`.
- **What happens:**
  - `isLeased` is checked, then the actor suspends twice, at the jobs read and the release write. A lease taken in between is ignored.
  - In practice this needs a job whose destination is no longer `active` (so it is not counted as needing the file) while its attempt sits between `fileExists` and `lease` (`UploadAttempt.swift:67-80`). That window is narrow.
- **Fix:** Re-check `isLeased` right before `remove`, or take the lease before the existence check.

## Checked and found sound

- No `await` inside a GRDB write closure: they are all synchronous.
- `JobRepository.apply` and `upsert` read and write in one transaction. Stale-read races in `UploadAttempt` are rejected by the transition table.
- Drive uploads reserve and save ids before creating anything. `alreadyExists` is checked with a probe, and `settle` and `replaceContent` act only on ids the job owns or that recovery matched.
- Recovery leaves unmatched files untouched. `RecoveryWriter` skips jobs that are `uploading`.
- The only things the engine trashes are its own shortcuts, and Drive's `trashShortcut` checks the mime type.
- Staging stops growing for offline or paused destinations: `exportCandidates` and `jobsNeedingStaging` require `active`, and the staging cap holds.
- Privacy: no file names, coordinates or tokens in log calls. `DestinationError.description` leaves out paths and ids.

## Unresolved questions

1. NFR-01: does "crash" include power loss and kernel panics? If yes, I6 is Critical.
2. Should owner commands wait for the running cycle, or run against a per-destination lock?
