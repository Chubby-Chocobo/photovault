# Full audit: app layer, AppSupport, config/CI, docs accuracy

Branch `review/full-codebase-audit` @ 451f1c3 (= release/0.1.0). Read-only review of `PhotoVault/**`, `Sources/PhotoVaultAppSupport/**` with its tests, `Config/**`, `PhotoVault.xcodeproj`, `.github/workflows/**`, `Package.swift`, `README.md` and `docs/**/*.md`. Items fixed in rounds 1–4 are not repeated.

Checks I ran:
- `swift test --filter PhotoVaultAppSupportTests`: 105 tests in 19 suites passed.
- `swift test list`: 733 tests (AppSupport 105, Core 133, Drive 103, Engine 262, Local 53, Photos 25, Store 52).
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build`: BUILD SUCCEEDED with no warnings.

There are no Critical findings. Eight findings are Important.

## Important

**I1. A partial first start makes later onboarding answers silently ignored.**
- Where:
  - `AppModel+FirstStart.swift:75`: `createDriveDestination` returns early when a Drive row exists.
  - `AppModel+FirstStart.swift:50`: the NAS is skipped when its row exists.
  - `OnboardingView.swift:7,17`: `OnboardingModel` is `@State` on the window, so it is lost when the window closes.
- Scenario:
  1. The owner presses Bắt đầu. The Drive root and row are created with scope `full` and account A.
  2. `commit(nas)` throws, for example because the NAS was unmounted after step 7's test. Or the app quits before `beginBaseline`.
  3. The owner relaunches, or closes the window and reopens it with "Mở thiết lập…". Onboarding starts again with a fresh model.
  4. The owner now picks `newOnly`, a new root name, no NAS, or signs in as account B. `signIn` installs B's token (`GoogleAuthSession.swift:62`).
  5. Start keeps the old row: scope `full`, A's root and A's `accountId`, plus any committed NAS. Result: either a full-library backfill the owner declined, or B's token checking A's root (404, then `rootMissing`, then a decision card) right after setup.
- Same-session variant: after a reopen, `facts.started` is true (`OnboardingModel.swift:54`). Back and the sidebar are disabled (`OnboardingFlow.swift:79,87`) and Bắt đầu is hidden (`OnboardingView.swift:108`). The only way forward is "Thử lại" with the new answers, which are ignored.
- Fix: keep the plan on `AppModel` (it already owns `firstStart`). Alternatively, when a row exists, compare it with the new plan and update scope, root and account, or refuse with a message. Also restore the wizard to the Start step when `firstStart != nil`.

**I2. A Settings change is dropped without feedback while any other field is invalid.**
- Where: `AppModel+Settings.swift:14-16` validates the whole draft and returns without saving when `issues` is not empty. The issues are shown only in Advanced (`AdvancedTab.swift:30`, under the disk section) and Organization (`OrganizationTab.swift:26`, day threshold only).
- Scenario:
  1. The owner types an integrity interval of 0 (or low ≤ critical) in Nâng cao.
  2. They switch to Nội dung and turn off Sidecar JSON, or turn on Album Hidden. In Chung they toggle launch at login.
  3. The toggle shows the new state, but nothing is saved. The engine keeps uploading sidecars that contain exact GPS. After a relaunch the toggle shows the old value again.
- Fix: validate and save per field (apply the valid keys), or show a global "Settings chưa lưu" banner on every tab while `settingsIssues` is not empty.

**I3. FR-61 "Ổ Mac đầy > 24 giờ" can never fire.**
- Where: `AppModel+Notifications.swift:12` reads `kv.mac_disk_full_since` through `AppQueries.swift:130`, and `NotificationPolicy.swift:71` depends on it.
- `grep` finds no writer of `KeyValueRepository.Key.macDiskFullSince` anywhere in `Sources/` or `PhotoVault/`.
- Spec 8.5 also asks for this notification when the disk stops work for more than 24 hours.
- `system-architecture.md:235` says the timestamp is stored, which is false.
- Fix: in `ResourceGuard.enforce` (or the cycle's disk check), set the key on the first critical observation and clear it when free space is back at or above the resume level.

**I4. "Không sync được > 24 giờ" fires almost never.**
- Where: `SyncCoordinator+Cycle.swift:181,208-211`. `recordSuccess()` writes `last_successful_sync_at` at the end of every cycle that does not throw.
- That includes cycles where every upload failed transiently (Drive 5xx for days), where uploads were held (`report.uploadsHeld` on a hotspot or by the AC-only rule), or where nothing could be exported.
- The hourly timer keeps refreshing the timestamp, so `NotificationPolicy.swift:73-75` never sees 24 hours. The owner is never told that backups stopped.
- Fix: record success only when the cycle had no pending work left, or when at least one upload or stage made progress. Alternatively, track `lastUploadProgressAt` while jobs are pending.

**I5. After a critical disk, export resumes up to 60 minutes later, but the card says "kiểm tra mỗi 15 phút".**
- Where: `MenuBarCards.swift:12` promises a 15-minute check, as spec 8.5 requires ("kiểm tra mỗi 15 phút").
- `SyncScheduler.swift:27-31` runs the 5-minute timer only for local `.unavailable` destinations (`AppModel.swift:154-158`). Otherwise only the hourly activity runs. No 15-minute disk re-check exists (grep for `15 * 60` finds only `ClassifyWorker`).
- Scenario: the owner frees 20 GB. Nothing exports until the next hourly, wake, mount or network trigger.
- Fix: in `needsAvailabilityRecheck`, also return true while `diskState != .ok`, and make that timer 15 minutes or reuse it. Alternatively, fix the copy.

**I6. There is no "sign in again" path. The only route says Drive will be reset.**
- Where:
  - `NotificationContent.swift:12` (reauthRequired) says "Mở PhotoVault › Settings để đăng nhập lại".
  - `GeneralTab.swift:24-30` offers only "Đổi tài khoản…" and "Đăng xuất…". After sign-out it still shows the e-mail as if the owner were signed in.
  - `AccountSheets.swift:25` warns "Trạng thái đích Drive sẽ được đặt lại".
- With the same account, the model commits and resumes without a reset (`AppModel+Account.swift:85-95`), so the warning is false. It is the most common real event (T21, a revoked grant, a "Testing" consent screen).
- The menu bar shows only the status label, with no action.
- Fix: when Drive is `reauthRequired` or `signedOut`, show "Đăng nhập lại…" (same `beginAccountChange` flow) in Chung and as a menu-bar card. Word the sheet so that the reset applies only to a different account.

**I7. CI: when two pushes to main arrive close together, the earlier release merge is never tagged.**
- Where: `ci.yml:15-17` sets `group: ci-${{ github.ref }}-${{ github.event_name }}` with `cancel-in-progress: true`.
- When `ci.yml` is called from `adf-git-guards.yml:67-69`, the `github` context is the caller's. Every main push therefore lands in `ci-refs/heads/main-push`.
- Scenario: the release merge to main starts `verify`, and a direct chore push to main follows a minute later. The second run cancels the first `verify`. `tag-release` (`needs: [guard-main-push, verify]`, `:76`) is skipped for the release SHA, and the later run tags nothing.
- This defeats the caller's own per-SHA concurrency (`adf-git-guards.yml:16-20`).
- Fix: in `ci.yml` use `group: ci-${{ github.workflow }}-${{ github.event_name == 'push' && github.sha || github.ref }}`, or drop `cancel-in-progress` when it runs as a reusable workflow.

**I8. Docs say things the code contradicts.**
- `README.md:5`: "The menu bar, onboarding and Settings are still being written". They are complete. `:127`: "will be refined when the UI is in the app".
- `codebase-summary.md:66` says "all package tests (594 tests)", but `:56` and my measurement give 733.
- `codebase-summary.md:22` says "migration `v1`", while `system-architecture.md:215` lists `v1` and `v2-upload-intent`.
- `codebase-summary.md:27` says AppSupport has 20 files. It has 23: `DestinationNesting`, `ProgressWatchdog` and `IntegrityNoticeText` are not listed.
- `codebase-summary.md:30` says `PhotoVault/Engine` has 12 files. It has 13: `DailyCapFile.swift` is missing from the list.
- `system-architecture.md:235` says the kv table holds the "Mac disk-full timestamp". Nothing writes it (I3).
- `system-architecture.md:93` says "Integrity check every 7 days". The interval now comes from `integrityCheckIntervalDays` (`IntegrityChecker.swift:263`).
- `docs/README.md:49` and spec §14 expect a `CHANGELOG.md`. None exists on release/0.1.0: `7cad755` changed only `Version.xcconfig`.

## Suggestion

**S1. Onboarding: an abandoned sign-in tab that completes later destroys the live token.**
- Where: `OnboardingModel.swift:108-111`. Huỷ only bumps the generation. The loopback keeps listening for 300 s because the task is not cancelled.
- Scenario:
  1. The owner signs in again in a new tab. That sign-in succeeds.
  2. The owner then completes the old tab. `signIn` installs its token (`GoogleAuthSession.swift:62`), and `:93-96` calls `signOut()`, which deletes the Keychain item and revokes the token.
  3. The UI still shows "Đã đăng nhập", and Start fails with reauth.
- Fix: keep the sign-in `Task` and cancel it in `cancelSignIn`, as `AccountChangeSheet` already does.

**S2. A 10-second idle poll does synchronous disk work on the main thread.**
- `AppModel.swift:168-175` calls `refresh()` every 10 s, forever:
  - `env.disk.capacity` (`:221`) reads `volumeAvailableCapacityForImportantUsageKey` (`VolumeDiskSpaceProvider.swift:11-13`), which can be slow (CacheDelete).
  - The notification ledger is read from disk (`AppModel+Notifications.swift:29`).
  - Several database reads run.
- This works against NFR-03 (idle CPU ≈ 0). Poll only while `snapshot.overall == .syncing`, and move the capacity call off the main actor.
- Related: `AppEnvironment.make` opens and migrates the database (including `VACUUM INTO` before a migration) on the main thread at launch.

**S3. `removeDestination` deletes the row before stopping its uploads.**
- `AppModel+Destinations.swift:146-147`: the row and its jobs are removed, and only then does `destinationRemoved` cancel the transfers.
- An upload that finishes in that window writes job state for a row that no longer exists. The cycle then ends with an error and the run's results are lost.
- Fix: call `destinationRemoved` first, then delete the row.

**S4. `addLocalDestination` can half-commit.**
- `commit` writes the marker, the row and the registry entry (`:84-91`) before `destinationAdded` (`:105`).
- If `destinationAdded` throws, the destination is live without its backfill jobs (FR-71). Pressing "Thêm" again fails on the duplicate row, and the sheet stays open with an error.
- Fix: register only after `destinationAdded` succeeds. Alternatively, on a retry, detect the existing row and call only `destinationAdded`.

**S5. First start reports a failure while the engine is already running.**
- `AppModel+FirstStart.swift:138-146` catches only `.alreadyRunning` and `needsOwnerDecision`.
- A reused NAS that is offline at that moment (`notReady(.destinationUnavailable)`) or a `cloudIdsPending` error ends with "Không bắt đầu được". By then `goLive` has run and Drive is uploading.
- Fix: treat `notReady` as "will continue in the background" (the cycle's `runPending` retries it) and finish the first start.

**S6. Sign-out does not stop Drive first.**
- `AppModel+Account.swift:40-49` revokes and deletes the token while uploads are in flight, then writes `signedOut`.
- An upload that fails during the revoke can record `paused(reauthRequired)` after or around that write. The owner then gets the "Phiên đăng nhập … đã hết hạn" notification right after signing out on purpose.
- Fix: `coordinator.pause(.googleDrive)` and cancel uploads before `auth.signOut()`.

**S7. Limited Photos access stops backups without a notification.**
- `NotificationPolicy.swift:51` fires `photosPermissionLost` only for `.denied` and `.restricted`. `allowsReading` is false for `.limited` (`PhotosSource.swift:7`), so the engine is blocked.
- `syncStalled` also requires `allowsReading`. A switch to Limited is therefore visible only in the popover.

**S8. "Tiếp tục không dùng dữ liệu cũ" acts with one click.**
- `DecisionCard.swift:110` has no confirmation step. The action re-uploads the whole scope beside the old data at the destination, which can double Drive usage, and it cannot be undone.
- Fix: add a confirm step like `confirmReupload`.

**S9. "Để sau" hides the card for the whole session, even after a later check finds more files.**
- The decision id has no count (`HardeningCommands.swift:84`), and the snooze set lasts the session (`AppModel+Hardening.swift:123`).
- The 12-hour notification keeps saying "Mở menu bar để quyết định" (`NotificationContent.swift:18`), but the card is hidden.
- Fix: include the count in the snooze key, or clear snoozes when the count changes.

**S10. Copy that contradicts behaviour.**
- `PlacesTab.swift:66` computes hours as `cells / 20 / 60`. With the default `vi`, each cell costs two requests (`GeocodeScheduler.swift:49-52`), so the time shown is half the real time. Spec: 10 000 cells ≈ 17 h.
- `OnboardingSteps2.swift:151-153` shows the scan as "/ N asset" with N taken from the scope count. For `newOnly` it reads "/ 0 asset", but the scan lists the whole library (FR-10).
- The Summary's "Asset sẽ backup" (`OnboardingModel.swift:181`, `LibraryCounter.swift:11`) includes hidden assets, which are off by default.
- `revealInFinder` on an unmounted NAS says "Hãy chọn lại thư mục" (`AppModel+Sync.swift:57`). The single-NAS menu row is not disabled when that NAS is offline (`MenuBarActions.swift:18-19`).

**S11. "Lần cuối" counts only manual integrity checks.**
- `AppQueries.swift:103-109` and `AppModel+Hardening.swift:35-38` record only "Kiểm tra ngay". A setup that relies on the scheduled check shows "Chưa kiểm tra lần nào" forever (`AdvancedTab.swift:46`).
- A manual check where every destination was skipped is still recorded as a check.

**S12. Mockup gap: the "views off" state is missing.**
- `settings.html:130` shows "drive.file không cho tạo shortcut nên view đang tắt".
- `OrganizationTab` has no such state. If the engine gets `viewsNotPermitted`, the three toggles stay on and the item estimate counts shortcuts that will never exist.

**S13. Unpinned toolchain, and a placeholder setting with a misleading name.**
- `ci.yml:29` uses `xcode-version: latest-stable`, so the toolchain moves under the build (README pins "Xcode 26 with Swift 6.1"). Pin a version.
- `Package.swift:4-5`: `strictSwift` is an empty array passed to every target, which is misleading. Remove it, or put real flags in it.

**S14. Local roots: only nesting with other local destinations is refused.**
- `AppModel+Destinations.swift:30-40` refuses only nesting with other local destinations.
- Picking `~/Pictures`, the home folder or a whole NAS share means `list(under: nil)` (`RecoveryTriggers.swift:57`, `IntegrityChecker.swift:156`) walks everything under it, `Photos Library.photoslibrary` included. Spec §9 says the library is never read directly.
- Not verified: whether the walk descends into packages.
- Fix: warn on a non-empty folder without a marker, and refuse one that contains `*.photoslibrary`.

**S15. The onboarding window can open behind other apps.**
- `AppModel.swift:121` sets `windowRequest = .onboarding` without `NSApp.activate`.
- An `LSUIElement` app launched at login stays inactive, so the window can open behind other apps. The `AppDelegate.swift:5` comment ("windows … bring the app forward themselves") is not true for `openWindow`.

## Verified sound (no finding)
- **Launch order:** container resolve, then `InstanceLock`, then database, then registry (`AppEnvironment.swift:69-131`). A lock failure ends in an alert and a quit.
- **Account change (round-4 N1/N2):** `DestinationHealth` now skips `paused(.signedOut)`. Cancelling the account sheet cancels the loopback through `withTaskCancellationHandler`.
- **Notification throttle:** load, plan and save run with no `await` between them, so overlapping `refresh()` calls cannot double-post. The ledger survives relaunch, and a clock that moves backwards does not mute notifications.
- **Log redaction:**
  - The HTTP log keeps only the method, host and path template.
  - `DestinationError.description` drops its payloads.
  - The `"\(error)"` log sites are all `DestinationError`.
  - Unified log entries are marked public only after `LogRedactor`.
- **Monitors:**
  - All captures are weak, and observers are removed on `stop`.
  - `PowerSourceWatcher` removes its run-loop source in `deinit`.
  - The runtime starts once (`goLive` guard).
  - `ActivityAssertion` is ref-counted and uses `.idleSystemSleepDisabled` only, which matches NFR-02.
- **Entitlements and Info.plist:**
  - Entitlements: sandbox, photos-library, network client and server (loopback), user-selected read-write, app-scope bookmarks.
  - Hardened runtime is on (`Base.xcconfig`).
  - Info.plist has `LSUIElement` and `NSPhotoLibraryUsageDescription`.
  - The secrets and team xcconfigs are gitignored and both have `.example` files.
- **CI hygiene:** actions are pinned by SHA, `permissions: contents: read` is set (write only for `tag-release`), and branch names reach scripts through `env`, not inline expressions.
- **Confirmation before destructive actions:** remove destination, sign out, resort, rebuild views, re-upload, rules and scope changes, and root change.
- **Retry safety:** baseline is idempotent on a first-start retry (`Baseline.swift:18`). Reconciliation is refused before the scan is complete.
- **README setup facts match the code:** dev container path, Keychain service and account, sandbox container path, Info.plist keys, and every linked doc exists.

## Unresolved questions
- I1: when the plan changes after a partial start, should onboarding update the existing Drive row, or refuse and ask the owner to reset?
- I4: what should "sync được" mean for FR-61: a cycle completed, or a file reached a destination?
- S7: can macOS 14/15 actually grant `.limited` Photos access to a Mac app? If not, S7 is moot.

Status: DONE_WITH_CONCERNS
Summary: There are no Critical findings and 8 Important ones. The main ones: onboarding answers are ignored after a partial first start; Settings edits are dropped without feedback while another field is invalid; two FR-61 notifications (Mac disk full, sync stalled) effectively never fire; the 15-minute disk recheck is missing; there is no re-sign-in path; CI concurrency can skip release tagging; and the README and codebase summary contain false statements. The app builds clean, 105 AppSupport tests pass, and 733 tests are listed.
