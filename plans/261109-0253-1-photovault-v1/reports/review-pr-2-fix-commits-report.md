# Review: PR #2 fix commits (`20c9266..HEAD`)

Scope: the app↔engine adapter, the Local small-file read, and every review-fix commit, checked against the three earlier reports. I read the code and only wrote to scratch files.

Checks I ran:
- `swift test`: 691 tests in 110 suites passed.
- An exFAT disk-image experiment for the bookmark/mount behaviour (finding 1).
- An instrumented copy of `ExclusiveLaneTests` in the scratchpad, to time the lane and cancellation (finding 12).

## Deadlock / lane analysis (no defect found)
- No `exclusive` body calls `exclusive` or `run`. `runReconciliation` and `startRecovery` call `run` only after the lane is released.
- `pause` and `pauseAll` do not take the lane, so `AppModel+Account` doing `pause` → `changeDriveRoot` cannot deadlock.
- The gate closure re-enters the coordinator. That is safe because the actor is reentrant and the lane is a separate actor.
- No lost wake-up in `ExclusiveLane`:
  - All state changes are synchronous inside the actor.
  - The `running = false` → `endCycle` window parks a second cycle in `cycle`, and `grant()` resumes it.
- `BlockingQueue` resumes exactly once.
- `commonAncestor` is fixed and has a test.
- The `v2-upload-intent` migration is additive. `resetState` and `deleteDependents` clear intents, and `upload_job.id` is AUTOINCREMENT, so an id is never reused.
- Staging lease and release are decided inside the actor before the first suspension. That is correct.
- `DailyCapFile` coalescing does not lose the final in-process write: a record that arrives after the drain schedules a new write on the serial queue.

## Findings

### Important

1. **An unplugged disk or NAS is reported as "root deleted" when another volume with the same name is mounted.**
   - Where: `Sources/PhotoVaultLocal/RootState.swift:19-27`, `RootAccess.swift:100-101`.
   - Verified: I created a bookmark on an exFAT image "PV Test Vol", detached it, then mounted a different image with the same name. Resolution with `.withoutMounting` fails with Cocoa code 4. `/Volumes/PV Test Vol` exists, so `missingError` returns `.rootMissing` instead of `.offline`.
   - Impact:
     - The destination goes to `paused(.rootMissing)`, which is an owner-decision state (`RootProblemService.swift:27`).
     - The FR-61 "folder deleted" alert fires for a disk that was only unplugged.
     - Default volume names collide often ("Untitled", "NO NAME", two NAS shares called "photo").
     - Any root outside `/Volumes` (autofs, a custom mount point) is always `rootMissing`.
   - Fix: return `rootMissing` only when the bookmark's volume UUID (`.volumeUUIDStringKey` from `resourceValues(fromBookmarkData:)`) matches the volume now mounted at that path. Otherwise return `offline`.

2. **The adapter turns "Check all" into "abort on the first offline destination".**
   - Where: `PhotoVault/Engine/EngineHardeningCommands.swift:15-23` calls `runIntegrityCheck(id)` once per destination. `IntegrityChecker.swift:34` swallows `DestinationError` only `where id == nil`.
   - Scenario: Drive is checked first and its missing files are marked. The NAS is unplugged, so its probe throws `.offline`. The whole command throws, Drive's summary is discarded, `integrityMismatches` is not updated, and the owner sees only an error.
   - Fix: catch `DestinationError` per destination in the loop, or skip destinations that are not `acceptsUploads`.

3. **Checksum mismatches are counted twice in the integrity notice.**
   - Where: `EngineHardeningCommands.swift:24-27`.
   - `missing` uses `report.missingByDestination[destination]`, which `IntegrityChecker.swift:47` defines as `missing + sizeMismatch + hashMismatch`. `mismatched` is then added on top.
   - Scenario: 0 missing and 3 bit-rot files. The notice reads "thiếu 3 file, 3 file lệch checksum", and the menu bar shows both an integrityMissing card and a checksumMismatch card.
   - Fix: use `report.missing` for the missing count.

4. **The original Local/App finding 9 is only partly fixed: mismatches found by the scheduled check never notify.**
   - Where: `integrityMismatches` is filled only by the manual check (`AppModel+Hardening.swift:42`) and lives in memory only (`AppModel.swift:38`).
   - `IntegrityStage` (`IntegrityChecker.swift:229+`) runs inside the cycle, and its results never reach `decisions`, so FR-61 "Checksum lệch" still cannot fire for the 7-day check.
   - The card also survives `confirmReupload` and disappears on relaunch.
   - Fix: let the engine expose mismatch counts through `pendingOwnerDecisions`, for example from the `missingFile` activity or a per-destination kv entry.

5. **Account change: a failure after `commitAccountChange` leaves account B live while the DB still describes account A.**
   - Where: `PhotoVault/App/AppModel+Account.swift:94-96`.
   - The commit happens before `switchDriveRoot`. `changeDriveRoot` → `RecoveryTriggers.reset` then makes a network call (`checkRoot`, `RecoveryTriggers.swift:82-87`) that can throw: offline, a 5xx, or `stillMissing`/`stillTrashed` for a reused root.
   - The sheet stays open with `change` set. If the owner presses Huỷ, `discardAccountChange` is a no-op because `pendingStage` was already cleared, and Drive resumes.
   - Uploads then go out with B's token to A's folder ids. That is the original Drive I1 failure: `folderMissing` → `markBranchMissing` on A's done files.
   - Pressing Áp dụng again fails with "account change no longer pending".
   - Fix: verify the root with the staged drive before committing. Alternatively, keep the old refresh token and restore it, and leave Drive paused when the reset fails.

6. **Account change: pressing Huỷ while waiting for the browser leaves Drive paused as "paused by you" indefinitely.**
   - Where: `AccountSheets.swift:75-79`. `cancel()` sees `change == nil` and only dismisses, while the `signIn()` Task keeps waiting on the loopback for up to 300 s.
   - If the owner then finishes in the browser with a different account, `beginAccountChange` (`AppModel+Account.swift:61,70`) returns a stage that nobody discards or resumes. Drive stays `paused(.userPaused)`, which the owner never chose.
   - The same happens if the app quits while the sheet is on `chooseRoot`.
   - This is a partial fix of the original Drive finding 1.
   - Fix: keep the sign-in Task in `@State` and cancel it in `cancel()` and in `onDisappear`. Use a dedicated pause reason, not `.userPaused`, so the pause can be undone at launch.

7. **The first-start "scan stalled" watchdog fires on a scan that is still making progress.**
   - Where: `AppModel+FirstStart.swift:102-123`.
   - During the initial scan the signature never changes:
     - `scanState` stays `.running`.
     - `overall` stays `.syncing`.
     - `pending` and `backfillTotalAssets` count `upload_job` rows (`EngineQueries.swift:204-213`), and no job exists until `FinalizePass` runs after the scan (`Scanner.swift:35-43` writes only assets and resources).
   - Any scan longer than 10 minutes therefore fails onboarding with "không tiến triển", although the scan continues in the background.
   - Fix: add scanned-asset progress, such as the asset count or the scan cursor, to the snapshot and the signature.

8. **On first start, a reused destination is recovered twice.**
   - Where: `AppModel+FirstStart.swift:134-137`.
   - `stillRequired` is read before `startRecovery` waits for the lane. `waitForScan` returns within 1 s of the scan completing, while the cycle is still in `tracker.process` / `finalize.runAfterScan`, so `recoveryRequired` is still true.
   - The cycle then runs `hardening.recovery.runPending()` (`SyncCoordinator+Cycle.swift:132`). At the next pass boundary the command runs `recover(id)` again, and `RecoveryService.swift:81-97` has no "already recovered" guard.
   - Result:
     - `enter()` pauses the destination as `recovering` again.
     - The whole root is listed and matched a second time (Drive API quota, and minutes on a large root).
     - `.alreadyRunning` never triggers, because the first run has finished by then.
   - Fix: re-check `recoveryRequired` inside the exclusive body, either in `SyncCoordinator.startRecovery` or in `RecoveryService.recover`.

### Suggestion

9. **Owner commands can wait for the whole first scan.**
   - Where: `SyncCoordinator+Cycle.swift:109-134`. The only pass boundary before the round loop is after the checks.
   - Scan, change tracking, reconciliation, `FinalizePass` and recovery all run without yielding. "Remove destination", settings save, retry and the integrity check all block for that whole time, which can be many minutes on a first scan.
   - Fix: add `await lane.yieldToCommands()` between scan batches and finalize pages.

10. **A waiting command can end the cycle with the backlog untouched and no follow-up cycle.**
    - Where: `UploadRunner.swift:127-133` together with `SyncCoordinator+Cycle.swift:168`.
    - If the gate refuses before any job is in flight, the round has `progress == 0` and the loop breaks.
    - `retryDeferred`, `confirmReupload` and other commands do not call `run` afterwards, so uploads wait for the next timer trigger.
    - Fix: set `followUp = true` when the gate refused because of a waiting command.

11. **The serial `BlockingQueue` per destination halves local upload concurrency.**
    - Where: `LocalFolderDestination.swift:26`, `FolderLockManager.swift:57-62`.
    - `maxConcurrentUploadsPerDestination = 2` is now effectively 1.
    - Every probe, hash, `checkAvailability` and recovery read queues behind a multi-GB NAS copy.
    - NFR-03 says "at most 2", so this is a trade-off, but it is not documented. Consider a concurrent queue with a width of 2.

12. **The lane tests take time without proving their claims.**
    - `changingTheDriveRootStopsOnlyThatDestinationsTransfers` (`ExclusiveLaneTests.swift:151-176`) takes 60 s. My instrumentation showed the first transfer is cancelled within 1 ms. The post-reset upload then sleeps for the full 60 s (`:163`), because the sleep is not limited to the first call.
    - `commandsRunOneAfterTheOtherWhenNoCycleIsRunning` (`:178`) would pass with interleaved commands too, so it proves nothing about serialization.

13. **`DailyCapFile` can drop the newest state on quit.**
    - Where: `PhotoVault/Engine/DailyCapFile.swift:26`. The write is an async block on a utility queue, and nothing flushes it on `applicationWillTerminate`.
    - The newest reservation can be lost, so the cap can be under-counted by up to one file.
    - Fix: drain synchronously on terminate.

14. **Header classification memory is still under-estimated.**
    - Where: `HeaderClassifier.swift`. It now buffers up to 32 MiB per classify, but `ClassifyWorker.swift:23` still admits work with an estimate of 1 MiB.
    - Concurrent classifies of large screenshots can each hold 32 MiB that `ResourceGuard` does not account for.
    - Fix: lower `maxBuffered` (the file is reread from disk anyway) or raise the estimate.

15. **Durability and per-volume notes.**
    - `Store.swift:43-49` applies `synchronous = FULL` plus `fullfsync` to every write transaction, including scan batches and the several transitions each job goes through. The cost has not been measured; NFR-03 says idle CPU should be about 0. Worth one benchmark before release.
    - `ExclusiveRenameMemo` is keyed by `dev_t` for the whole process. A device number reused after a remount sends an APFS volume down the check-then-rename path.

## Original findings: status
- **Engine report:** C1, C2, I3, I4, I5, I6, I7, M8 and M9 are all fixed.
- **Drive report:**
  - Fixed: 2, 3 (cap persisted and reserved, write token bucket added), 4, 5, 6, 7, 8 and 10.
  - **1 is partial** (findings 5 and 6).
  - **9 is partial** (finding 14).
- **Local/App report:**
  - Fixed: 1, 2 (with the false positive in finding 1), 3, 4, 5, 7, 8, 10, 11, 12, 13 (with the trade-off in finding 11) and 14 (by path; case-insensitive spellings and different mount points of one share are not caught).
  - **6 is partial:** ENAMETOOLONG is still the generic item-level `itemRejected`.
  - **9 is partial** (finding 4).
  - **15 is partial** (finding 7).
- **Anti-slop:**
  - No plan, phase or finding IDs in code. `M0-3` and FR numbers are spec references.
  - `IntegrityWalker` and `FolderRenameRecovery` were removed.

## Unresolved questions
- Should `rootMissing` for local destinations clear on its own when the volume returns, or stay an owner decision? This decides whether finding 1 is just noise or stops backups.
- Is effective concurrency 1 per local destination (finding 11) intended?

Scratch artefacts, safe to delete: `/private/tmp/claude-501/-Users-annh-workspace-photovault/c95079e8-f124-4c29-8253-08dccc3843e6/scratchpad/pvcopy` and `.../scratchpad/bm`.
