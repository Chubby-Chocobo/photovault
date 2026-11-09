# Review: PR #2 round-3 fixes (`8d906e4..HEAD`)

Scope: dfa6c8c (Local), 7d01596 (app), 4556044 (engine), 9edb912 (docs), checked against `review-pr-2-round-2-report.md`. No code changed.

Checks run:
- `swift test --scratch-path .build-main --filter "AccountChange|Recovery|LocalRootState|Integrity|ExclusiveLane"`: 113 tests in 21 suites passed.
- `xcodebuild -scheme PhotoVault CODE_SIGNING_ALLOWED=NO build`: BUILD SUCCEEDED.

## Round-2 items

| # | Status | Evidence |
|---|--------|----------|
| I1 Huỷ during Áp dụng | fixed | `AccountSheets.swift:37` (disabled while working), `:50` (onDisappear guarded), `:80` (guard in `cancel`). The sheet is the only caller of `cancelAccountChange`. |
| I2 Staged Drive visible to the cycle | fixed, but see R1 | The staged destination is never registered. The check, the Keychain commit and the reset run in one exclusive body (`SyncCoordinator+Hardening.swift:100-111`, `RecoveryTriggers.swift:79-86`). New regression: R1. |
| I3 Repeated recovery | fixed | The flag is read inside the lane (`SyncCoordinator+Hardening.swift:119-123`). First start passes `onlyIfRequired: true` (`AppModel+FirstStart.swift:132`). The owner's request stays unconditional (`HardeningCommands.swift:313-318`). |
| I4 Stale integrity result after reset | fixed | `RecoveryTriggers.swift:144-146` |
| I5 Mismatch counted twice | fixed as asked; regression R3 | `HardeningServices.swift:49-54` |
| S1 Quit leaves Drive paused | fixed (tiny residual, S-b) | Marker at `AppModel+Account.swift:64-72`; cleared at launch (`:128-135`, `AppModel.swift:228`). |
| S2 Transient error stops "Check all" | fixed | `EngineHardeningCommands.swift:24-35` |
| S3 Volumes without a UUID | partly | `ATTR_CMN_RETURNED_ATTRS` is now requested (`ExclusiveRenameMemo.swift:22-36`). RootState compares the remount URL (`RootState.swift:582-584`). Not verified on a real SMB share (S-a). |
| S4 Watchdog vs commands | approach changed; regression R2 | `AppModel+FirstStart.swift:179-192` |

## Findings

### Important

**R1. A successful account change can raise a false "Không tìm thấy thư mục gốc" (rootMissing) and a notification.**
- Where:
  - `AppModel+Account.swift:152-162`: `env.drive.setRootId(root.id)` runs only after `changeDriveAccount` has returned, so after the lane is released and after `publish()`, a MainActor hop and a kv write (`:160`).
  - `install` (`GoogleAuthSession.swift:93-98`) switches `env.drive` to account B's token at commit time, inside the lane.
  - `GoogleDriveDestination.checkAvailability` (`:52-56`) checks the in-memory `rootId`, which is still A's root.
- Scenario (`createNew`):
  1. `apply` sets Drive to `.active` (`RecoveryTriggers.swift:131-134`).
  2. A cycle waiting on the lane (a followUp, a Photos change or a timer) starts as soon as `endCommand` runs.
  3. That cycle's `DestinationHealth.refresh` (`DestinationHealth.swift:14-20`) calls `checkRoot(A's root)` with B's token. The `drive.file` scope gives a 404, so Drive is set to `.paused(.rootMissing)`.
  4. `NotificationPolicy.swift:59` posts `folderTrashedOrMissing`, and the menu bar shows a rootMissing card for a root that was just created.
- Self-heals: yes, at the next cycle. Round 2 did not have this window, because the staged Drive was registered with the right root.
- Fix:
  - Set the live root inside the engine step: in the `commitAccount` closure, after `commitAccountChange`, call `await env.drive.setRootId(root.id)`.
  - In the `committed` catch branch, restore the old root id. Otherwise a later same-account sign-in leaves A's token pointed at B's root.
  - `switchDriveRoot` (`:224-228`) has the same window. It is harmless there only because the same token can still see the old root.

**R2. The scan watchdog no longer sees any progress during the scan; it is now a fixed 30-minute deadline.**
- Where: `AppModel+FirstStart.swift:179-192`. The signature is now the snapshot with only `updatedAt` and `etaSeconds` blanked.
- Why nothing moves:
  - `SnapshotBuilder.swift:17-29` holds `scanState` (only `notStarted/running/complete`), job counts, backfill counts, bytes and destination statuses.
  - The scanner creates no jobs (no Job or Intent references in `Scanner.swift`). The removed comment said so too.
  - So the signature is constant from the first `running` until `complete`. The asset count, the one signal that moved per batch, was removed.
- Scenario: a large or iCloud-optimised library whose scan takes more than 30 minutes fails onboarding with "không tiến triển trong 30 phút", even though every batch is progressing.
- Fix: keep `AssetRepository.count` (or the scan cursor) in the signature. For S4, also reset the watchdog while `lane.hasWaitingCommands` is true or a command holds the lane.

**R3. Mismatched files lost their only re-upload path, and a stale mismatch count can hide real missing files.**
- Where:
  - `HardeningServices.swift:50-54` subtracts the stored mismatch count from `missingRemote`.
  - The `checksumMismatch` card has no re-upload action (`DecisionCard.swift:108-113`: Xem hoạt động / Đã xem / Để sau). Only `integrityMissing` reaches `confirmReupload` (`:89-99`).
- Scenario A:
  1. A check finds 0 gone and 3 mismatched files. The jobs are `missingRemote` and the kv mismatch count is 3.
  2. Only the mismatch card shows, and it cannot re-upload anything. The owner presses "Đã xem" and no card is left.
  3. The 3 corrupt backups stay `missingRemote`. `upsert` ignores that state (`JobTransitions.swift:237`).
  4. Nothing changes until the next scheduled check, which by default is days away. Before round 3, the "thiếu 3 file / Upload lại" card covered them.
- Scenario B:
  - The kv count is cleared only by `confirmReupload` or a new check.
  - If one of the mismatched jobs leaves `missingRemote` some other way (for example, the asset is cancelled by narrowing), the stored 3 now exceeds the jobs it describes.
  - `max(0, total - 3)` then hides that many genuinely gone files.
- Fix:
  - Keep the `integrityMissing` card counting every `missingRemote` job, and word it as "thiếu N file (trong đó M lệch checksum)". Keep the mismatch card as information only.
  - Alternatively, add "Upload lại" to the mismatch card. Clamp the subtraction to the mismatched jobs that are still `missingRemote` (store their identities rather than a count).

### Suggestion

**S-a. Remount-URL identity gives `.offline`, never `rootMissing`, when the same share comes back under another URL.**
- Where: `RootState.swift:582-584` compares `volumeURLForRemounting.absoluteString` exactly.
- Scenario: the bookmark holds `smb://alice@nas.local/photo`. The share is later mounted as `smb://bob@nas.local/photo` (another user), `smb://192.168.1.10/photo` (by IP) or through a Bonjour alias, and the folder really was deleted.
- Result: the destination stays "offline" forever, and the owner is never asked about the missing root.
- This is the safe direction: it never triggers a false rootMissing.
- Fix: compare scheme, host (case-insensitive) and share path, and ignore the user. Log the mismatch.
- Also: a mounted volume with a nil remount URL (some NFS or WebDAV mounts) is also always `.offline`. Unverified on real hardware.

**S-b. Residual commit-then-fail windows leave Keychain B against database A.**
- Window 1 (app quit): quitting between `commitAccountChange` and the `apply` write (`RecoveryTriggers.swift:84-85`, milliseconds) leaves Keychain B, the database on A and the marker set.
  - At relaunch, `clearStaleAccountChangePause` resumes Drive. B's token on A's root then gives a false rootMissing, and "Upload lại vào thư mục mới" would fill B while `accountId` still says A.
- Window 2 (failed write): `markDriveSignedOut` is `try?` (`AppModel+Account.swift:189-195`), and the marker is cleared before it runs (`:170`).
  - If that write fails too, which is likely when `apply` just failed on the database, Drive stays `userPaused` with no marker. A manual resume then hits the same mismatch.
- Fix:
  - Clear the marker only after `markDriveSignedOut` succeeds.
  - Optionally, persist the staged account id with the marker, so that launch can tell a half-done change apart and mark Drive signed out.

**S-c. No test covers "commit succeeded, reset failed", the stale `rootId` window, or the watchdog signature.**
- `AccountChangeTests.swift` covers a failing commit, a missing root, lane ordering and success.
- The app-side branches (`committed.isSet`, marker clearing, the launch resume) and `waitForScan` are untested, because the app target has no tests.

## Regression checks with no defect found
- Cancelling before the lane:
  - `cancelUploads` before `exclusive` only stops transfers. If the check or commit then fails, `cancelAccountChange` resumes Drive. Only `.userPaused` set by this change is lifted.
- Pause marker ordering:
  - Each quit point before the lane (marker set but not paused; paused and waiting for the browser; staged) recovers correctly at launch.
  - The launch check only lifts `.userPaused`.
- `onlyIfRequired`:
  - `resetState` sets `recoveryRequired = true` (`DestinationRepository.swift:88`), so a reused root always qualifies.
  - The skip returns an empty `.recovered` and does not run an extra cycle.
- `CommitFlag`: `commitAccountChange` is atomic (`GoogleAuthSession.swift:81-86`), so the flag correctly separates "Keychain changed" from "not changed".
- `ATTR_CMN_RETURNED_ATTRS` layout: length 4 B, `attribute_set_t` 20 B, then `uuid_t` at offset 24, matching the reply order.

## Unresolved questions
- R3: should mismatched files be re-uploadable from the mismatch card itself, or only as part of the "thiếu N file" card?
- R2: what scan duration is expected for the largest supported library? The watchdog limit should come from that.
