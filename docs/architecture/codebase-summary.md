# Codebase summary

Last updated: 2026-11-09. Derived from the source tree (file and line counts with `find` and `wc`) and from `swift test list`. For the architecture itself see [system-architecture.md](./system-architecture.md).

## Stack

| Item | Value | Source |
|---|---|---|
| Language | Swift 6, language mode v6 | [Package.swift](../../Package.swift) |
| Tools version | 6.1 | Package.swift |
| Minimum macOS | 14 | Package.swift `platforms` |
| Persistence | GRDB.swift 7.12 or later (SQLite, WAL) | Package.swift, `Store.swift` |
| UI | SwiftUI and AppKit, `MenuBarExtra` | `PhotoVault/` |
| Tests | Swift Testing (`import Testing`) | [decision 0004](../decisions/0004-swift-testing.md) |
| Toolchain used for this summary | Swift 6.3.2 (`swift --version`) | local run |

## Directory map

| Path | Files | Lines | Purpose |
|---|---|---|---|
| `Sources/PhotoVaultCore/` | 39 | 3,799 | Contracts and pure rules, no I/O. `Models/` (value types, settings, snapshots), `Entities/` (persisted rows), `Protocols/` (`Destination`, `PhotosSource`, `Clock`, `ReverseGeocoding`, `LogSink`), `Rules/` (`JobTransitions`, `Eligibility`, `CategoryClassifier`, naming, layout, `ResourcePlanner`), `Policies/` (backoff, token bucket, disk guard, place naming, sidecar JSON and XMP, view rules and diff, device names), `Errors/` (`DestinationError`, `ErrorClassifier`), `Codecs/` (`AppPropertyCodec`), `Localization/` (`L10n`, `tr(vi:en:)`, `AppLanguage`, `InterfaceLanguageChoice`), `Resources/device-names.json` |
| `Sources/PhotoVaultStore/` | 18 | 1,815 | GRDB store. `Store.swift` (open, WAL, read and write), `Schema.swift` (migrations `v1`, `v2-upload-intent`, `v3-snapshot-counters`, `v4-provisional-index`), `SchemaSnapshotCounters.swift` (the v3 and v4 DDL and the triggers that keep the snapshot counters), `SnapshotCounterRepository.swift`, one repository file per table group, `DatabaseBackup.swift`, `RowDecoding.swift` |
| `Sources/PhotoVaultPhotos/` | 14 | 953 | PhotoKit adapter. `PhotoKitSource*.swift` (library snapshots, persistent changes, export), `ResourceRequestSession.swift`, `StalledRequestGuard.swift` (gives up on a request that delivers nothing for 15 minutes), `StreamingFileWriter.swift` (inline MD5 and SHA-256), `HeaderClassifier*.swift`, `ImageIOMetadataReader.swift`, `CLGeocoderReverseGeocoder.swift`, `UTTypeResolver.swift`, `PhotosErrorMapper.swift` |
| `Sources/PhotoVaultDrive/` | 20 | 1,750 | Google Drive. `OAuthClient.swift`, `PKCE.swift`, `LoopbackRedirectServer.swift`, `LoopbackRequestParser.swift`, `IDToken.swift`, `KeychainStore.swift`, `GoogleAuthSession.swift`, `HTTPTransport.swift`, `DriveAPI.swift`, `DriveHTTP.swift`, `DriveQuery.swift`, `DriveModels.swift`, `DriveErrorMapper.swift`, `ResumableUploader.swift`, `DailyUploadCap.swift`, `DriveWriteLimiter.swift`, `GoogleDriveDestination*.swift` (core, root, views) |
| `Sources/PhotoVaultLocal/` | 15 | 1,530 | Local and NAS folders. `LocalFolderDestination.swift`, `LocalFileOps*.swift` (fd-relative operations), `AtomicFileWriter.swift`, `DirectoryHandle.swift`, `FolderLockManager.swift`, `RootAccess.swift` + `RootState.swift` (bookmark, trash and mount detection), `ExclusiveRenameMemo.swift`, `BlockingQueue.swift`, `FileHashing.swift`, `DestinationMarker.swift`, `LocalPath.swift` |
| `Sources/PhotoVaultEngine/` | 70 | 8,645 | Sync engine. `SyncCoordinator*.swift` (cycle, owner actions), `EngineSnapshot.swift` (`CycleStep`, `CycleStage`), `EngineEnvironment.swift`, `ChangeTracker.swift`, `Scanner.swift`, `Baseline.swift`, `ClassifyWorker.swift`, `ClassifyQueries.swift` (which provisional assets need a header read), `ExportWorker.swift`, `ExportWorker+SizeRules.swift` (oversized resources), `ResourceGuard.swift`, `StagingManager.swift`, `UploadRunner.swift`, `UploadAttempt.swift`, `FolderEnsurer.swift`, `EditGate.swift`, `Sidecar*.swift`, `View*.swift`, `ViewRebuildPreparation.swift` (first half of a view rebuild), `MoveWorker.swift`, `MoveRecovery.swift`, `PlaceNamer.swift`, `GeocodeScheduler.swift`, `Recovery*.swift`, `IntegrityChecker.swift`, `IntegrityDrive.swift` (state of each expected Drive item), `IntegrityLocal.swift`, `Reconciler.swift`, `StartupRecovery.swift`, `CloudIdBackfill.swift`, `InstanceLock.swift`, `ContainerLocator.swift`, `ActivityLog.swift`, `DestinationHealth.swift`, `DeferredJobSweeper.swift`, `*Stage*` files for the cycle stages |
| `Sources/PhotoVaultAppSupport/` | 23 | 1,428 | App logic without AppKit or SwiftUI. `NotificationPolicy.swift`, `NotificationKind.swift`, `NotificationContent.swift`, `NotificationLedgerFile.swift`, `OnboardingFlow.swift`, `SettingsForm.swift`, `StatusText.swift`, `OverallStatusText.swift`, `ProgressText.swift`, `ProgressWatchdog.swift`, `ActivityPresentation.swift`, `VietnameseFormat.swift` (number and size text; grouping follows the interface language), `RelativeTimeText.swift`, `ErrorText.swift`, `IntegrityNoticeText.swift`, `LogRedactor.swift`, `AppLogSink.swift`, `RotatingFileLog.swift`, `TriggerDebouncer.swift`, `MacDiskState.swift`, `DestinationRulesEditor.swift`, `DestinationNesting.swift` (no destination root inside another), `PhotoVaultAppSupportModule.swift` |
| `Sources/PhotoVaultTestSupport/` | 4 | 870 | Shared fakes: `FakePhotosSource.swift`, `FakeDestination.swift`, `TestEnvironmentFakes.swift`, `DestinationConformanceSuite.swift` |
| `PhotoVault/App/` | 12 | | `AppModel.swift` and extensions (`+Account`, `+Sync`, `+Settings`, `+Destinations`, `+Organization`, `+Hardening`, `+Notifications`, `+FirstStart`, `+Bindings`), `AppDelegate.swift`, `WindowRequest.swift` |
| `PhotoVault/Engine/` | 13 | | Launch glue: `AppEnvironment.swift` (composition root), `SyncScheduler.swift`, `PhotosChangeObserver.swift`, `SystemMonitor.swift`, `PowerSource.swift`, `WorkspaceMonitor.swift`, `VolumeDiskSpaceProvider.swift`, `ActivityAssertion.swift`, `AppQueries.swift`, `DailyCapFile.swift` (persists the Drive daily upload cap), `HardeningCommands.swift`, `EngineHardeningCommands.swift`, `LocalContentReader.swift` |
| `PhotoVault/Views/` | 25 | | SwiftUI: `MenuBar/`, `Onboarding/`, `Settings/` (one file per tab, `RulesEditor.swift`, `AccountSheets.swift`), `Activity/ActivityView.swift`, `Shared/` |
| `PhotoVault/Services/` | 5 | | `DriveRootService.swift`, `LibraryCounter.swift`, `LoginItemService.swift`, `NotificationService.swift`, `FolderPicker.swift` |
| `PhotoVault/PhotoVaultApp.swift` | 1 | | `@main` entry point |
| `PhotoVault.xcodeproj/` | | | Hand-written project, file-system synchronized groups, depends on the local package ([decision 0002](../decisions/0002-hand-written-xcode-project.md)) |
| `Config/` | 6 | | `Base.xcconfig`, `Version.xcconfig`, `Local.xcconfig.example`, `Secrets.xcconfig.example` (the real `Secrets.xcconfig` is gitignored), `PhotoVault-Info.plist`, `PhotoVault.entitlements` |
| `Tests/` | 109 | 14,087 | Seven test targets, see below |
| `docs/` | | | Living documentation: `requirements/`, `architecture/`, `decisions/` (ADRs 0001–0021), `spikes/` (M0 owner procedures), `conventions/`, `design/` (HTML mockups), `sidecar-schema.md`, `test-report.md` |
| `plans/` | | | Dated working material (plans, reports); not project truth |
| `.github/workflows/` | 2 | | `ci.yml` (build, test, unsigned app build on `macos-15`) and ADF's git guard workflow |

Source totals: 203 Swift files, 20,824 lines under `Sources/` (including `PhotoVaultTestSupport`). App target: 56 Swift files, 5,170 lines.

## Test targets

Counts are tests reported by `swift test list` on 2026-11-09. Parameterised and generated cases are counted individually.

| Target | Tests | Main subjects |
|---|---|---|
| `PhotoVaultCoreTests` | 135 | Job transitions, eligibility, classification, naming, layout, rate limiting, disk guard, sidecar builders, place naming, view rules, device names, models and codecs |
| `PhotoVaultStoreTests` | 59 | Schema and migration, repositories, backups (including restore from a backup), placement and name allocation, job and resource state, snapshot counters |
| `PhotoVaultPhotosTests` | 31 | Header classifier, metadata reader, UTI and RAW detection, streaming writer, stalled-request guard |
| `PhotoVaultDriveTests` | 105 | OAuth (PKCE, loopback, token handling), Keychain query, Drive REST and query escaping, resumable upload, Drive destination, redaction |
| `PhotoVaultLocalTests` | 66 | Atomic writes, symlink refusal, folder safety, root state (trash, missing, offline), metadata marker, small-file reads, conformance suite |
| `PhotoVaultEngineTests` | 302 | Sync cycle, scan and change tracking, export, upload errors, crash recovery, recovery from destinations, integrity, views, sidecars, place naming, disk and power gates, instance lock |
| `PhotoVaultAppSupportTests` | 108 | Notification policy, log redaction and rotation, status and progress text, onboarding flow, settings form, Vietnamese formatting, debouncer |
| **Total** | **806** | 135 suites in the full run |

The app target has no tests. Its logic is kept in packages where it can be tested; the remaining app code is UI and launch glue.

## Build and test

Run from the repository root.

```bash
swift build                      # SPM build of all library targets
swift test                       # all package tests (806 tests)
swift test --filter EngineTests  # one target, by name fragment
```

Unsigned app build, as CI runs it:

```bash
xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation
```

Running the app:

- Signed build (Personal Team, from `/Applications`): data lives in the sandbox container.
- Unsigned build: refused unless started with `--dev-container`, which uses `~/Library/Application Support/PhotoVault-dev` ([decision 0009](../decisions/0009-sandbox-container.md)).
- Google sign-in needs `Config/Secrets.xcconfig`, copied from `Config/Secrets.xcconfig.example`. The file is gitignored. Keys are never committed.

The full test result and the spec coverage are in [test-report.md](../test-report.md).

## Entry points

| Need | Start with |
|---|---|
| Run one sync cycle | `Sources/PhotoVaultEngine/SyncCoordinator.swift` (`run(trigger:)`, `cycle`) |
| Job state rules | `Sources/PhotoVaultCore/Rules/JobTransitions.swift` |
| Eligibility per destination | `Sources/PhotoVaultCore/Rules/Eligibility.swift` |
| Destination contract | `Sources/PhotoVaultCore/Protocols/Destination.swift` |
| Database schema | `Sources/PhotoVaultStore/Schema.swift` |
| Sidecar format | `Sources/PhotoVaultCore/Policies/SidecarBuilder.swift`, [sidecar-schema.md](../sidecar-schema.md) |
| Composition root | `PhotoVault/Engine/AppEnvironment.swift` |
| Settings defaults | `Sources/PhotoVaultCore/Models/Settings.swift` |
