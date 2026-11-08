# Review: PR #2 round-2 fixes (`a052e30..HEAD`)

Scope: 064c3fe (Local), b336163 (app), b42807f (engine), 8d906e4 (docs), checked against `review-pr-2-fix-commits-report.md`. I did not change any code.

Checks I ran:
- `swift build --build-tests`, then `swift test --filter` on the seven suites these commits touch: 41 tests in 7 suites passed. I did not re-run the full suite.
- `xcodebuild` for the app target, unsigned: BUILD SUCCEEDED.

## Status of the previous report's items

| # | Item | Status | Evidence |
|---|------|--------|----------|
| 1 | An unplugged volume is reported as "root deleted" | **partly** | Volumes that have a UUID are fixed (`RootState.swift:24-30`). Volumes without one fall back to the old name check, which is the NAS case (Suggestion S3). |
| 2 | "Check all" stops at the first offline destination | fixed, with a caveat | `IntegrityChecker.swift:38-50`, `EngineHardeningCommands.swift:24-27`. A transient error still stops the whole run (S2). |
| 3 | Checksum mismatches counted twice | **partly** | The notice text is fixed. The menu bar still shows two cards (finding I5). |
| 4 | The scheduled check's mismatches never notify | fixed | The results are stored in kv (`IntegrityChecker.swift:68-72`) and shown through `HardeningServices.swift:51-53`. The stored result is stale after a reset (I4). |
| 5 | Account committed before the reset | fixed | The commit now happens after `changeDriveRoot` (`AppModel+Account.swift:121-134`). New problems: I1 and I2. |
| 6 | Huỷ while waiting for the browser leaves Drive paused | **partly** | The sign-in task is now cancelled and the stage discarded (`AccountSheets.swift:40,78-83`, `AppModel+Account.swift:73-77`). Quitting the app mid-change still leaves `userPaused` (S1). |
| 7 | Scan watchdog fires on a scan that is progressing | fixed | The signature now uses the asset count (`AppModel+FirstStart.swift:117-118`). |
| 8 | Reused destination recovered twice | **partly** | The new guard only catches a recovery that finished while the request waited. One that finished before the request is repeated (I3). |
| 9 | Commands wait for the whole first scan | fixed | Commands are let in between scan batches and finalize pages (`SyncCoordinator+Cycle.swift:116-138`, `Scanner.swift:59`, `FinalizePass.swift:42`). |
| 10 | No follow-up cycle after a waiting command | fixed | `SyncCoordinator+Cycle.swift:84-88` |
| 11 | Probes wait behind copies on the serial queue | fixed | Probes moved to a separate metadata queue (`LocalFolderDestination.swift:17-18`). Copies and hashes stay serial on purpose. |
| 12 | Lane tests slow and unproven | fixed | Only the first transfer sleeps. Serialization is now proven by the enter/exit order (`ExclusiveLaneTests.swift:180-193`). |
| 13 | DailyCapFile may drop the newest state on quit | fixed | `DailyCapFile.swift:31-33`, called from `AppModel.swift:185` (`applicationWillTerminate`). |
| 14 | Header memory not counted | fixed | `ClassifyWorker.swift:23-32`, `ResourceGuard.swift:96` |
| 15a | `fullfsync` on every write | not addressed | It was a benchmark request, not a defect. |
| 15b | Rename memo keyed by `dev_t` | partly | Now keyed by `VolumeKey`, but see S3. |
| L6 | ENAMETOOLONG is a generic error | fixed | `ErrorClassifier.swift:92` |

## Regression checks with no defect found
- **Concurrent `ensureFolder`:** cannot create a folder twice. `mkdirat` tolerates EEXIST (`DirectoryHandle.swift:63`).
- **`ensureFolder` racing a rename:** the folder-lock rules are unchanged. Every interleaving the new metadata queue allows gives the same result as one of the two serial orderings.
- **Lane entry during the scan:** no deadlock.
  - The scanner re-reads its cursor from the database before every batch (`Scanner.swift:26-28`).
  - No command calls the scanner or `FinalizePass`.
  - Commands always go first and are finite, so the cycle is not starved.
- **DailyCapFile flush:** `queue.sync` from the main thread cannot deadlock, because `writePending` never hops back to main. A write already running finishes before the flush runs.
- **`followUp`:** cannot livelock. `hasWaitingCommands` clears at the next `yieldToCommands`.

## Findings

### Important

**I1. Pressing Huỷ (or closing Settings) while Áp dụng is running wipes the old account's Drive state.**
- Where:
  - `AccountSheets.swift:38`: Huỷ stays enabled while `working` is true.
  - `AccountSheets.swift:51`: `onDisappear` also calls `cancel()`.
  - `AppModel+Account.swift:101-104`: `cancelAccountChange` removes the token, discards the stage and resumes Drive.
  - `AppModel+Account.swift:110-134`: `applyAccountChange` never checks the token again after its awaits.
- Scenario:
  1. The owner presses Áp dụng. `changeDriveRoot` waits for the lane behind a long NAS copy.
  2. The owner presses Huỷ. The stage is discarded and Drive goes from `userPaused` to `active`.
  3. Apply continues. `reset` writes account B and B's root into the database and drops all of A's jobs and folders.
  4. `commitAccountChange` throws "no longer pending", because `pendingStage` is nil.
  5. `markDriveSignedOut` runs.
- Result: the owner pressed Cancel, but A's state is gone, the database names account B, and Drive is signed out. With `createNew`, an orphan root is also left in B's Drive.
- Fix:
  - Disable Huỷ and suppress the `onDisappear` cancel while `working` is true.
  - In the model, keep an "applying" set that `cancelAccountChange` refuses to touch.

**I2. The staged-account Drive is visible to the cycle outside the lane.**
- Where: `AppModel+Account.swift:119-120` registers it before the lane is taken (`SyncCoordinator+Hardening.swift:89-90`), and `:136-138` swaps it back only after the lane is released.
- What it has: it is built with `writeLimiter: nil` and a fresh, unpersisted `DailyUploadCap` (`:209-210`).
- Scenario A (before the reset):
  - The waiting command makes the upload gate refuse and sets `followUp` (`SyncCoordinator+Cycle.swift:84-88`).
  - If that round made no progress, the cycle ends. The follow-up cycle then runs `DestinationHealth.refresh()` before its first `yieldToCommands` (`:108-113`).
  - Precondition: Drive was not `active` before the change (`wasActive == false`, for example `paused(.reauthRequired)` or `unavailable(.offline)`), so it was not paused as `userPaused`.
  - `stagedDrive.checkAvailability()` then checks B's root with B's token and sets Drive to `active` (`DestinationHealth.swift:14-20`). The database still holds A's jobs and root.
  - `resolveInterrupted` probes A's file ids with B's token next.
  - If the reset then fails (a transient error in `checkRoot`), the registry goes back to `env.drive` but the database keeps the flipped status.
- Scenario B (after the reset, `createNew`):
  - The reset sets Drive `active` and the enqueue flag. The cycle continues: `runPending` enqueues everything, and `UploadRunner.runDestination` looks up `.googleDrive` (`UploadRunner.swift:110-111`).
  - If that happens before `commitAccountChange` and `registry.add(env.drive)`, the pass keeps the staged destination for its whole run, which can be hours.
  - Every write in that pass skips the shared `DriveWriteLimiter` and the persisted 24-hour cap. Its reservations are never recorded in `drive-daily-cap.json`.
- Also: when the commit fails, `:128-130` registers `env.drive` (A's token, B's root) *before* `markDriveSignedOut` runs. Drive is still `active` in that gap.
- Fix:
  - Swap the destination inside the exclusive body: pass the staged destination into `changeDriveRoot`, and restore `env.drive` on failure before the lane is released.
  - Commit the Keychain entry and register `env.drive` inside the same exclusive body. Alternatively, build the staged Drive with the shared limiter and cap.
  - On commit failure, mark the destination signed out before re-registering.

**I3. The recovery guard misses a recovery that finished before the request, and first start removed its own check.**
- Where:
  - `SyncCoordinator+Hardening.swift:100-101` passes `onlyIfStillRequired: required`, where `required` is read before the lane.
  - When that read is already `false`, the guard is off and `recover` lists the whole root again (`RecoveryService.swift:90,101`: `enter()` re-pauses the destination as `recovering`).
  - `AppModel+FirstStart.swift:132-135` no longer skips destinations whose `recoveryRequired` is already false.
- Scenario:
  1. A small library and a reused root.
  2. The cycle finishes the scan, `FinalizePass` and `runPending` recovery within the 1-second poll of `waitForScan`.
  3. `startRecovery` reads `recoveryRequired == false`, so the guard is not applied.
  4. Recovery runs a second time. Uploads that already started are paused, and the root is listed and matched again.
- The new test only covers the "finished while waiting" case (`RecoveryTests.swift:228`).
- Fix: give first start its own flag, such as `startRecovery(id, onlyIfRequired: true)`, which skips when the flag is false at any point. Keep the unconditional path for the owner's "Thử khôi phục lại".

**I4. Stored integrity results survive a reset, so a "Checksum lệch" card appears for a root that is no longer used.**
- Where: `RecoveryTriggers.swift:121-122`. The `exact` list clears `lastRunKey` but not `resultMissingKey`, `resultMismatchKey`, `resultAtKey` or `mismatchDismissedKey`.
- The card is built from those keys at `HardeningServices.swift:51-53`. The same reset is used by `RootProblemService.swift:84`.
- Scenario:
  1. A check finds 3 mismatches.
  2. The owner changes account (or picks a new root after `rootMissing`). Every job is dropped.
  3. "3 file lệch checksum" keeps showing for the new, empty root until the next check or a dismiss.
- Fix: add the four keys to the `exact` list.

**I5. The menu bar still counts mismatched files twice.**
- Where:
  - `IntegrityLocal.swift:48-51` marks mismatched files `missingRemote`.
  - `HardeningServices.swift:49-50` builds `integrityMissing` from the count of all `missingRemote` jobs.
  - `:51-53` then adds a `checksumMismatch` card with the same files.
- Scenario: 0 files gone and 3 bit-rot files. The notice is now correct ("3 file lệch checksum"), but the menu bar shows "thiếu 3 file" plus "3 file lệch checksum".
- Fix: build `integrityMissing` from `missingRemote` minus the stored mismatch count, or hide one card when the other covers it.

### Suggestion

**S1. Quitting the app during an account change leaves Drive paused.**
- Where: `openAccountChanges` is in memory only (`AppModel.swift:54`), and the pause reuses `.userPaused` (`AppModel+Account.swift:64`).
- The `onDisappear` Task (`AccountSheets.swift:51`) is not guaranteed to run before the app terminates.
- Result: after relaunch, Drive stays "paused by you", although the owner never chose that. This is the remaining part of item 6.
- Fix: use a dedicated reason, such as `paused(.accountChange)`, and clear it at launch.

**S2. A transient error still stops "Check all".**
- Where: when `runIntegrityCheck` is called with an id, `IntegrityChecker.swift:44` swallows only destination-level errors. `EngineHardeningCommands.swift:24` rethrows anything else and ends the loop.
- Scenario: a Drive 5xx or timeout, classified `.transient`, stops the run before the NAS is checked. Results already stored are kept, but the owner sees only an error.
- Fix: catch per destination in the adapter and add the destination to `skipped`.

**S3. Volumes without a UUID still fall back to the old behaviour. Not verified on a real SMB share.**
- `ExclusiveRenameMemo.swift:28-35`: `fgetattrlist` is not asked for `ATTR_CMN_RETURNED_ATTRS`. A filesystem without `ATTR_VOL_UUID` returns success with a zeroed UUID, so the `mountSource` fallback never runs. Every such volume is keyed `(dev, 00000000-…)`, which is the `dev_t`-only behaviour again.
- `RootState.swift:24-27`: SMB mounts usually have no `volumeUUIDString`. They take the `/Volumes/<name>` fallback, so the "two NAS shares named photo" false `rootMissing` from item 1 remains.
- Fix:
  - Request `ATTR_CMN_RETURNED_ATTRS` and treat a missing UUID as nil.
  - For roots without a UUID, compare `f_mntfromname`, stored at bookmark time, with the source mounted at that path now.

**S4. Commands let in during the scan can trip the onboarding watchdog.**
- Where: `AppModel+FirstStart.swift:117-119`.
- Since b42807f, a command can hold the lane mid-scan. During that time the asset count does not move.
- Scenario: "Kiểm tra ngay" during onboarding lists a large Drive root for more than 10 minutes, and onboarding fails with "không tiến triển".
- Fix: either reset the watchdog while `lane.hasWaitingCommands` is true or a command is running, or expose the scan cursor in the snapshot and use it as the signal.

## Unresolved questions
- I3: should the owner's own "Thử khôi phục lại" re-list a destination that does not need recovery? The new test (`anOwnerRequestForADestinationThatNeverNeededRecoveryStillRuns`) says yes. First start needs the opposite.
- I2: should the staged Drive share the live `DailyUploadCap`? The cap is per Google account, but the persisted file has a single entry.
