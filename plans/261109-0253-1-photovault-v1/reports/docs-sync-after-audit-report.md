# Docs sync after the audit fixes

Date: 2026-11-09. Branch: `review/full-codebase-audit`. Files changed: README.md, docs/architecture/codebase-summary.md, docs/architecture/system-architecture.md, docs/test-report.md. No code, no CHANGELOG.md, nothing staged or committed.

Verification: `swift test --scratch-path .build-docs` ran on the branch head and printed `Test run with 806 tests in 135 suites passed`. Per-target counts come from `swift test list`. File, line and migration facts come from `find`, `wc` and the Schema files. Each behaviour change was read in the code before it was written.

## Changes

### README.md

| Line | Was | Now | Why |
|---|---|---|---|
| 5 | "The menu bar, onboarding and Settings are still being written." | "the engine, the core packages, the menu bar, onboarding and Settings are in the repo." | Those views exist under `PhotoVault/Views/`. |
| 127 | "This section will be refined when the UI is in the app." (sentence removed) | Removed. | The UI is in the app. |

### docs/architecture/codebase-summary.md

| Line | Was | Now |
|---|---|---|
| 3 | Provenance cited `repomix-output.xml` at the repo root. The file does not exist. | "Derived from the source tree (file and line counts with `find` and `wc`) and from `swift test list`." No repomix file was created, because it is not gitignored and would be an untracked file outside the allowed scope. |
| 22 | Store: 15 files, 1,566 lines, migration `v1` only. | 18 files, 1,815 lines, migrations `v1`, `v2-upload-intent`, `v3-snapshot-counters`, `v4-provisional-index`. Lists `SchemaSnapshotCounters.swift` and `SnapshotCounterRepository.swift`. |
| 23 (Photos row) | 13 files, 816 lines. | 14 files, 953 lines. Adds `StalledRequestGuard.swift`. |
| 24 (Drive row) | 19 files, 1,457 lines. | 20 files, 1,750 lines. Adds `HTTPTransport.swift` and `DriveWriteLimiter.swift`. |
| 25 (Local row) | 1,283 lines. | 1,530 lines. |
| 21 (Core row) | 3,757 lines. | 3,799 lines. |
| 26 (Engine row) | 63 files, 7,628 lines, no new files listed. | 70 files, 8,645 lines. Adds `ClassifyQueries.swift`, `ExportWorker+SizeRules.swift`, `IntegrityDrive.swift`, `ViewRebuildPreparation.swift`. |
| 27 (AppSupport row) | 20 files, 1,300 lines, 19 names listed. | 23 files, 1,428 lines. Adds `DestinationNesting.swift`, `ProgressWatchdog.swift`, `IntegrityNoticeText.swift`, `PhotoVaultAppSupportModule.swift`. |
| 30 (PhotoVault/Engine row) | 12 files, `DailyCapFile.swift` missing. | 13 files. Adds `DailyCapFile.swift`. |
| 36 (Tests row) | 72 files, 10,279 lines. | 109 files, 14,087 lines. |
| 41 (Source totals) | 187 files, 18,632 lines; App 55 files, 4,637 lines. | 203 files, 20,824 lines; App 56 files, 5,170 lines. |
| 49–56 (test targets table) | Core 133, Store 52, Photos 25, Drive 103, Local 53, Engine 262, AppSupport 105, Total 733 in 119 suites. | Core 135, Store 59, Photos 31, Drive 105, Local 66, Engine 302, AppSupport 108, Total 806 in 135 suites. Store and Photos rows gain the snapshot-counter and stalled-request-guard subjects. |
| 66 (Build and test) | `swift test # all package tests (594 tests)` | `(806 tests)`. |

The `Tests/` row count: the brief's "72" was the file count for the seven test targets. The count above (109) is the verified file count.

### docs/architecture/system-architecture.md

| Line | Was | Now |
|---|---|---|
| 52 | `PhotoVaultStore`: "migration `v1`". | "migrations `v1` to `v4`". |
| 53 | PhotoKit adapter row, no timeout mentioned. | Adds "a request that delivers no data for 15 minutes is abandoned" (`StalledRequestGuard`, `defaultStallTimeout = 15 * 60`). |
| 93 | "Integrity check every 7 days." | "Integrity check every `integrityCheckIntervalDays` days (Settings, default 7)." (`Settings.swift:30`, `IntegrityChecker.swift:164-172`). |
| 94 | "The app observes snapshots." | Adds: `last_successful_sync_at` is set when the cycle uploaded something, or when no job was pending or uploading at an active destination. The app also re-reads the snapshot every 10 seconds while the overall state is `syncing` (`AppModel.swift`). |
| 163 (new row) | No row for corrupt-database restore. | "Corrupt database at launch": `DatabaseBackup.restoreNewest` called from `AppEnvironment`. The newest backup that passes `PRAGMA integrity_check` replaces the file. Every destination is marked `recovery_required`. Damaged files move aside as `<name>.corrupt-<time>`. Only SQLite corruption or not-a-database errors trigger it. Tests: `restoreNewestMarksEveryDestinationRecoveryRequired`, `theCorruptFileIsKeptAsideNotDeleted`, `onlyDamagedFilesCountAsCorruption`. |
| 184 | `list(under:)`: "Stream remote items for recovery and integrity". | Adds: Drive also streams trashed items, with `trashed` set (`GoogleDriveDestination.swift:152`). |
| 216 | Schema: migrations `v1` and `v2-upload-intent`. | Lists all four migrations. Notes the v3 and v4 DDL file and that the v3 triggers on `upload_job` keep the snapshot counters current. |
| 236 | `kv`: "Mac disk-full timestamp" with no writer described. | Adds `last_successful_sync_at` and `mac_disk_full_since`. The latter is written by `ResourceGuard` at the first pass below the critical watermark and cleared once the disk is above it (`ResourceGuard.swift:184-196`). |
| 286 | No scheduler timer description. | Adds: `SyncScheduler` runs the 60-minute background activity, a 5-minute re-check of unavailable local folders, and a 15-minute re-check while the Mac disk state is not OK (`SyncScheduler.swift`). |

Not changed, because verified as true: `DatabaseBackup` 24-hour and newest-7 rule; `list(under:)` remaining text; the kv keys' names.

### docs/test-report.md

| Line | Was | Now |
|---|---|---|
| 19–20 | Run output `733 tests in 119 suites`, `--scratch-path .build-main`. | `806 tests in 135 suites`, `--scratch-path .build-docs`, from the run this session. |
| 23 | "Tests: 733 in 119 suites, all passing. The unsigned app build ... also succeeds." | "806 in 135 suites, all passing (2026-11-09, after the audit fixes)." The unsigned app build sentence now says it was not re-run for this update, because I did not run `xcodebuild`. |
| 24 (new) | No list of audit-fix tests. | Lists the suites whose test files gained `@Test` declarations on this branch: `SettingsFormTests`, `DestinationRulesEditorTests`, `SettingsSavableTests`, `JobTransitionsTests`, `DriveQueryTests`, `DriveAPIRequestTests`, `ResumableFlowTests`, `ClassifyPassWalkTests`, `DeletedAssetAndClockTests`, `DirtyQueueSweepTests`, `EditGateTests`, `EngineQueriesApplyTests`, `ExportPassFailureTests`, `IntegrityRootStateTests`, `LastSuccessfulSyncTests`, `PlaceRefreshTests`, `RecoveryTriggerTests`, `ResourceGuardTests`, `SettingsStoreTests`, `UploadResumeParentTests`, `ViewRepairTests`, `LocalResilienceTests`, `ImageIOMetadataReaderTests`, `UTTypeResolverTests`, `PhotosErrorMapperTests`, `StalledRequestGuardTests`, `DatabaseBackupTests`, `PlacementTests`, `DayStatTests`, `SnapshotCounterTests`. |

T-table statuses checked and unchanged: T25 (`renameRoot` appears only as a pass-through in `HardeningTestKit.swift:197`, so "Not covered" still holds).

## Checked and left alone

- `docs/README.md:49` says release notes go in `CHANGELOG.md` at the repo root. That is a placement rule, not a claim that the file exists, so it is not false.
- README "Known limits" 7-day NAS notice: matches `NotificationPolicy.offlineThreshold` (7 days).
- README "Using the app" menu list: matches the labels in `MenuBarActions.swift` and `MenuBarView.swift`.
- The `validate-docs.cjs` run reports 58 valid internal links and no new link problems. Its code-reference warnings are for test suite names, because the script does not scan `Tests/`. All cited suite names exist. The `IMG_0001` config-key warning in `test-report.md` predates this change.

## Gaps and unresolved questions

1. **Repomix.** The codebase-summary workflow asks for a repomix compaction at `./repomix-output.xml`. I did not create it, because the brief limited me to four files. The provenance line now describes the real method. Decide whether the compaction should be generated and kept.
2. **Unsigned app build.** `xcodebuild … CODE_SIGNING_ALLOWED=NO` was not re-run, so the app-target claim is not re-verified after the audit fixes.
3. **Suite count.** My own tally of distinct `Target.Suite` names gave 137 (139 entries, two of them free-standing tests). The Swift Testing run reports 135, and the docs use 135. The run is the authority.
4. **Audit I8 items not in scope.** Items S1–S9 in the audit report are code fixes, not doc changes, so the docs do not describe them.

## Build artifacts

`.build-docs/` was created by the test run at the repo root. Git does not list it as untracked, so it is ignored. The temporary test-list files were moved out of the repo to the session scratchpad.

Status: DONE_WITH_CONCERNS
Summary: The four allowed docs now match the branch: README status and UI lines are corrected, codebase-summary counts, migrations and new files are updated to the verified state, and system-architecture covers the audited behaviours; test-report shows the real 806-test run. Repomix output was not generated and the unsigned app build was not re-run, so both are flagged for the controller.
