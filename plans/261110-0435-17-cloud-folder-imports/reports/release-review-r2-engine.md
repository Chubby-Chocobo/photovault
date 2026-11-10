# Release review r2: Core / Store / Engine (0.3.0, snapshot b9c704f)

- Scope: `git diff v0.2.0...b9c704f` for `Sources/PhotoVaultCore`, `Sources/PhotoVaultStore`, `Sources/PhotoVaultEngine` and their tests. Most attention went to the round-1 fixes in `21144c3..b9c704f` (mainly 143eec7). The app and adapters were read only where the engine contract depends on them (launch registration, scheduler, the Dropbox error mapping, the transport timeout).
- Tests: `swift test --skip ZZAudit` in a throwaway worktree at b9c704f ran 1167 tests in 196 suites, and all passed.
- Probes: 12 tests, run in throwaway worktrees at 21144c3 and at b9c704f. The b9c704f test kit was copied into the 21144c3 worktree so the probes compile there. Both worktrees have been removed. The probe files are kept at:
  - `/private/tmp/claude-501/-Users-annh-workspace-photovault/c95079e8-f124-4c29-8253-08dccc3843e6/scratchpad/ZZAuditR2Engine.swift`
  - `/private/tmp/claude-501/-Users-annh-workspace-photovault/c95079e8-f124-4c29-8253-08dccc3843e6/scratchpad/ZZAuditR2EngineMore.swift`

## Round-1 findings: status

| R1 | Probe | 21144c3 | b9c704f | Verdict |
|---|---|---|---|---|
| I1: a dropped connection fails the file | p1: one `.unavailable` on inspect, probe answers | `[imported 1, failed 1]` | `[imported 2]`, completed | Fixed |
| I2A: a file too large for the disk blocks the import | p2: a 200 GB file, 100 GB free, 5 h | `[pending 2]`, no reason | `[imported 1, pending 1]`, `diskFull` | Fixed |
| I2B: an always-busy file blocks the import | p3: `a.jpg` always busy | `[pending 2]` after 29 h | `[imported 1, pending 1]` at 5 h; `[imported 1, failed 1]`, completed, at 29 h | Fixed |
| M3: offline probe on every pass | p4: probe `.unavailable`, 5 runs, clock stopped | 5 probes | 0 probes | Fixed |
| M4: a revoked closed import makes one token refresh per file per hour | p5 / p5b: 30 and 250 files, count the adapter calls | 30 per run | 30 per run (30 files); 200 per hour (250 files) | **Partly fixed**; see Minor 3 |
| M5: a held export keeps an old `last_error` | p6 | error kept | cleared | Fixed |
| M6: sign-in does not release waiting exports | p7: revoke, resume, settle with the clock stopped | 0 done | 3 done | Fixed |
| M7: going back to 0.2.0 stops every cycle | — | — | — | Accepted and documented ("unsupported", plan.md) |

Regressions checked by probe:
- r1: a Mac folder file that cannot be read (`.unavailable`, folder still answers) still fails at once, and the job completes. Same result on both snapshots.
- `LocalFolderSource` never throws `.busy`, and the disk check runs only for cloud sources. A Mac-folder import therefore cannot fall into the new wait-without-limit paths.

## Critical

None found.

## Important

### 1. The 24-hour give-up counts time when the file was never tried, so two short failures a day apart lose the file
- **Where:**
  - `ImportHolds.shouldGiveUp` (`Sources/PhotoVaultEngine/ImportHolds.swift:52-58`) keeps the first failure time until a good read.
  - `waitsForRetry` (`ImportStage+Ingest.swift:75-85`) gives up on the first failure that lands 24 h or more after that time.
  - Nothing resets the clock while the job is offline, while the Mac sleeps or while the app is not cycling.
- **Scenario:**
  1. During a long Drive or Dropbox import, `a.jpg` gets one 429 or one stalled download. The probe answers, so the group waits.
  2. Before the next retry, the import goes offline (laptop away from Wi-Fi), or the Mac sleeps over a weekend, for more than 24 h.
  3. On the first retry after that, the file gets one more transient error (a burst 429, or a stall on a large video). It is marked `failed "read"` at once, after only two tries.
  4. The job completes with "1 lỗi"; the photo is not imported.
- **Evidence:** probe r2 (busy once, probe `.unavailable` for 30 h, then busy once):
  - b9c704f: `[imported 1, failed 1]`.
  - 21144c3: `[imported 2]`.
  - This contradicts ADR 0026 line 83 ("stays unreadable … for 24 hours").
- **Workaround:** import the folder again.
- **Fix:** do one of the following (each is small and stays wall-clock-based, as the decision requires).
  - Keep `last` next to `first`. When `now - last` is more than a gap such as 2 h, start the clock again from `now`.
  - Or give up only when both are true: at least 24 h have passed and there have been at least N failed tries.
  - Add the r2 probe as a test.

## Minor

### 2. Inside one group, giving up on a file restarts its clock while the group still waits, so an n-file group takes about n × 24 h
- **Where:** `ImportStage+Ingest.swift:75-85`, with the loop at `:66-95`.
  - When member 1 is given up, `holds.readable` clears its clock and `failed[...]` is filled.
  - If member 2 then returns `.waiting`, the group is not committed. The `failed` mark is dropped, and member 1 starts a fresh 24 h on the next pass.
- **Evidence:** probe r4. With `x.jpg` and `x.mov` (one group) both always busy, the group stays `pending 2` at 24, 30, 36 and 42 h, and becomes `failed 2` only at 46 h.
- **Impact:** a Live Photo or RAW+JPEG pair blocks the end of the import for about 2–3 days instead of 1.
- **Fix:** clear the clock only on a good read (`readable` after inspect succeeds), not on give-up. Or record the give-up per path, so the next pass marks the file failed without asking again.

### 3. "Asks the provider once" is not true: a revoked closed import still makes up to 200 adapter calls per hour
- **Where:**
  - `ExportWorker.dispatchNext` (`ExportWorker.swift:137-143`) pops candidates from `queue`, which is filled once per pass (`limit: 200`).
  - `ResourceRepository.beginExport` checks only `staging_state`, not `next_export_attempt_at`.
  - So `deferExports` hides the deferred rows from the *next* query, but not from the queue already in memory.
- **Evidence:**
  - p5 (30 files): 30 adapter calls in the first run and 30 an hour later. 21144c3 gives the same counts.
  - p5b (250 files): 200 calls in the first run, 0 in a second run within the same hour, and 200 an hour later.
  - The DB side works: the other import's 3 files exported fine.
- **Impact:** each call is a token refresh that gets `invalid_grant`, because the adapters do not cache a dead grant. That is about 200 per hour per revoked import, against "one" in ADR 0026 line 92 and the plan. The cost is far lower than in round 1 (one per file), so this stays Minor.
- **Test gap:** `CloudExportSignInTests.oneRevokedExportHoldsTheOtherFilesOfTheSameImport` checks only `next_export_attempt_at`, never how many times the provider was asked, so it passes while the claim is false.
- **Fix:**
  - In `runPass`, keep a per-pass `Set<SourceID>` of sources that were deferred. Have `dispatchNext` skip any candidate whose `asset.sourceId` is in that set; the asset is already loaded there.
  - Count adapter calls in the test.
  - With `maxConcurrentExports = 2`, "once" can honestly be "at most 2"; say so in the ADR.

### 4. Provider-wide trouble is handled one file at a time
- **Where:** `ingestBatch` / `process` (`ImportStage+Ingest.swift:10-45, 75-85`).
  - A `.waiting` group lets the loop go on to the next group, so one pass tries every group in the batch (`importBatchGroups = 100`).
  - The stage does not yield to owner commands inside the batch.
- **Scenario A (time):**
  1. Downloads stall while the small probe call still answers, for example on flaky Wi-Fi.
  2. Each group costs up to the 120 s request timeout (`URLSessionTransport(timeout: 120)`; Dropbox maps `.timedOut` to `.unavailable`) plus a probe.
  3. One `.classify` step can therefore run for up to about 100 × 2 min.
  4. Photos export and upload for that round, and the owner's Cancel or Pause, wait behind it.
  5. Each later pass retries the same groups once their 30 s blocks have expired.
  - In 21144c3 the same stalls failed the files instead (round-1 I1), so this cost is new with the retry.
- **Scenario B (data):** the download host refuses (5xx or 429) for more than 24 h while the API host answers the probe.
  - Every group in the batch that was tried is marked `failed`.
  - Probe r3: b9c704f gives `[failed 2]`, completed; 21144c3 gives `[imported 2]` once the provider recovers.
  - This matches the 24 h decision, but up to 100 groups per day of outage fail, not one file.
- **Fix:** after K consecutive `.waiting` groups in one pass (for example 3) with no commit, stop the batch and call `pauseBriefly`. A single bad file still does not block the others, and trouble across the whole provider costs one short pass.

### 5. A blocked group's retry waits for the next trigger, not the 30 s cooldown
- **Where:**
  - When every pending group is blocked, `ingestBatch` returns `false` (`:16-22`) and the cycle drains.
  - The availability recheck timer (`SyncScheduler`, every 5 min) only fires for Mac-folder *destinations*.
  - A blocked cloud group is therefore retried on the hourly timer, or on a Photos or network trigger.
- **Impact:**
  - The last file of an import that hit one 429 or dropped connection waits up to an hour.
  - The 24 h give-up then rests on about 24 tries. That is acceptable, but the "30 s cooldown" in ADR 0026 is not what the owner sees.
- **Fix (optional):** have `needsAvailabilityRecheck` also return true while some open import has `statusReason != nil` or blocked groups. Or document that retries follow the cycle triggers.

### 6. One committed test assertion proves nothing
- **Where:** `CloudImportWaitingTests.aBusyFileThatRecoversIsNotGivenUp`, last block.
- **Why:** by then `a.jpg` is already `imported`, so making it busy again cannot change `[.failed]`; the assertion passes whatever `shouldGiveUp` does.
- **Fix:** to prove "the clock starts again after a good read", fail a *different*, still-pending read after the recovery. Alternatively, unit-test `ImportHolds` directly: call `shouldGiveUp`, then `readable`, then `shouldGiveUp` again with the clock 25 h on, and expect false.

## Checked, no finding

- **`nextGroups` SQL** (`ImportItemRepository.swift:22-36`): the positional arguments are in the order `[id, id, excluded…, limit]`, which matches the SQL. Groups are never split. The excluded set is bounded by the groups tried in one 30 s window.
- **`deferExports` / `releaseExports`:**
  - Both are limited by `asset.source_id`, and `asset_source(source_id, deleted_at)` exists. Another import and Photos are untouched: p5's second import exported all 3 files.
  - Only `staging_state = 'none'` rows are touched, so staged and in-flight exports keep their state.
  - `releaseExports` also drops item-level backoffs for that source, which costs one early retry each; harmless.
- **Clearing `last_error` on a held export:** this applies only to folder or cloud errors that are busy or source-level. `export_attempts` is untouched, so `exportGaveUp` still triggers on real item-level failures. Later real failures are recorded again. Photos (`folder == nil`) is unchanged.
- **`diskFull` reason:**
  - It is written only while the job is `scanning` and never overwrites `signInRequired` or `unavailable`.
  - It clears on the next pass with room, on `resume` and on `finish`, and after a relaunch.
  - It can flicker when the disk-waiting group is outside the current batch and its block has expired. This is cosmetic.
- **Cooldowns versus Photos:**
  - An all-blocked import returns `false`, so it does not keep the round loop alive.
  - `.waiting` with no commit sets a job hold, so the next round skips the import without probing (p4).
  - The sign-in backoff is 10 min.
- **Clocks:** `ImportHolds` and the export deferral use the injected `env.clock`. There is no use of `Date()` in the new code.
- **Concurrency:**
  - `ImportHolds` is shared by reference, and every access is under its `NSLock`.
  - `resumeImportAfterSignIn` runs in the exclusive lane.
  - `setStatus` and `showDiskWait` re-read the row, so a cancel that lands meanwhile wins.
- **Launch order:** `registerSources` runs before `coordinator.start()` (`AppModel.goLive`). A closed import that has a token is never mistaken for "adapter missing", marked `signInRequired` and deferred.
- **Sidecar name:** `SourceConfig.sidecarName` is optional with synthesized `Codable`, so old rows decode unchanged. A Mac folder keeps `displayName`.
- **Crash safety:** the commit per group is unchanged (`commitGroup` is one transaction and keeps the `isOpen` guard). A group that is waiting writes nothing.
- **Privacy:** the new log lines carry no id, path, name or email ("import file waits for disk room", "source busy; import group waits", "import file unreadable for a day; marked failed").

## Unresolved questions

1. Important 1 and Minor 2 change how the give-up behaves. Is "the last failure more than 2 h ago starts the clock again" acceptable within the lead's wall-clock decision, or is a minimum number of tries preferred?
2. Minor 4: is stopping a pass after a few consecutive waiting groups acceptable, or must every group be tried on every pass?
3. Round-1 Q1 (a Google re-pick merges ids into `remoteItems`, but a listed job never lists again) is unchanged in the engine. Is it still intended that re-signing in only restores the grant?

Counts: Critical 0 / Important 1 / Minor 5
Status: DONE_WITH_CONCERNS
