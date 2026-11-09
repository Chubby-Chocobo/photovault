# Test report

Date: 2026-11-09. Spec: [photovault-spec-v1.md §11](./requirements/photovault-spec-v1.md) (T1–T43, with the lettered variants T4b, T27b, T27c, T30b: 47 rows).

Status meanings:

| Status | Meaning |
|---|---|
| Automated | A Swift test asserts the spec expectation with fakes or fixtures. Real-world confirmation may still be listed under "Owner check". |
| Partially automated | Part of the expectation is asserted. The rest needs a real device, service or long run. |
| Manual | No automated test. The owner checks it by hand. |
| Not covered | No test and no owner procedure yet. |

## Automated run

Final run on the branch head after the review fixes (2026-11-09):

```text
swift test --scratch-path .build-docs
✔ Test run with 806 tests in 135 suites passed after 19.791 seconds.
```

- Tests: 806 in 135 suites, all passing (2026-11-09, after the audit fixes). The unsigned app build (`xcodebuild … CODE_SIGNING_ALLOWED=NO`) was not re-run for this update.
- Tests added by the audit fixes are in these suites: `SettingsFormTests`, `DestinationRulesEditorTests`, `SettingsSavableTests`, `JobTransitionsTests`, `DriveQueryTests`, `DriveAPIRequestTests`, `ResumableFlowTests`, `ClassifyPassWalkTests`, `DeletedAssetAndClockTests`, `DirtyQueueSweepTests`, `EditGateTests`, `EngineQueriesApplyTests`, `ExportPassFailureTests`, `IntegrityRootStateTests`, `LastSuccessfulSyncTests`, `PlaceRefreshTests`, `RecoveryTriggerTests`, `ResourceGuardTests`, `SettingsStoreTests`, `UploadResumeParentTests`, `ViewRepairTests`, `LocalResilienceTests`, `ImageIOMetadataReaderTests`, `UTTypeResolverTests`, `PhotosErrorMapperTests`, `StalledRequestGuardTests`, `DatabaseBackupTests`, `PlacementTests`, `DayStatTests`, `SnapshotCounterTests`.
- An earlier snapshot taken while the Drive fixes were half applied showed 3 loopback OAuth failures; they do not reproduce on the final tree (`OAuthPrimitivesTests` 8 of 8 pass on their own and in the full run).
- Two timing-sensitive tests were made deterministic: `AuthSessionTests` no longer shares one fake clock between parallel tests, and `TriggerDebouncerTests` polls for the expected fire instead of fixed sleeps.
- **Real-file camera detection** is covered at two levels. `RawHeaderFixtureTests` uses the opening bytes of 21 public-domain RAW files kept in git. `MediaCorpusTests` uses 27 complete files (about 750 MB) that CI fetches by checksum and caches. Run locally on 2026-11-09:

  ```text
  PHOTOVAULT_MEDIA_CORPUS=.media-corpus swift test
  ✔ Test run with 821 tests in 137 suites passed after 20.546 seconds.
  ```

  With the UTI hint removed, 26 issues fail across both suites.
- Per-target counts: [codebase-summary.md](./architecture/codebase-summary.md#test-targets).

## Spec §11 coverage

Test names are from `Tests/**`. Spec expectations and the fakes used are in each test file.

| ID | Scenario (spec §11) | Status | Swift test(s) | Owner check or reason |
|---|---|---|---|---|
| T1 | `newOnly` does not upload old photos | Automated | `ScanAndChangeTests.t1NewOnlyDoesNotUploadOldPhotos`; `ClassificationEligibilityTests.newOnlySkipsOldPhotosAndTakesNewOnes` | — |
| T2 | `since(30 days)` uploads newest first | Automated | `ScanAndChangeTests.t2SinceUploadsNewestFirst`; `ClassificationEligibilityTests.sinceUsesArchiveDayOrWindow` | — |
| T3 | `newOnly` to `full` uploads each file once | Automated | `ScanAndChangeTests.t3NewOnlyToFullUploadsEachFileOnce` | — |
| T4 | Photo taken during scan is uploaded in all three modes | Automated | `ScanAndChangeTests.t4PhotoAddedDuringScanIsUploadedInEveryMode`; `ScanAndChangeTests.t4PhotoAddedBehindTheCursorIsPickedUpByChanges` | Real capture during a scan (on device). |
| T4b | Token expired, 50 new photos, reopen: all uploaded; unhidden photo not new | Automated | `ReconciliationTests.t4bTokenExpiredWithFiftyNewPhotosUploadsAllOfThemAndAnUnhiddenPhotoIsNotNew` | Real token expiry (optional). |
| T5 | Old photo imported after the baseline is uploaded | Automated | `ScanAndChangeTests.t5OldPhotoImportedAfterBaselineIsUploaded` | Real import in Photos (on device). |
| T6 | 1,000+ mixed assets: every burst frame uploaded, hidden excluded | Automated | `RulesAndLayoutTests.t6MixedLibraryUploadsEveryFrameAndNoHiddenAsset` (1,000 fake assets) | Real library of 1,000+ assets (on device). |
| T7 | RAW-only and a drone video over 4 GB reach both destinations, same checksum and EXIF | Partially automated | `ExportWorkerTests.exportStoresHashesSizeAndCameraMetadata`; `StreamingFileWriterTests.streamingSHA256MatchesKnownVector`; `LocalWriteTests.passesConformanceSuite` | No test uses a file over 4 GB or a real RAW. Owner: real library and Drive ([M0-1b](./spikes/m0-1b-resource-bytes-and-mapping.md)). |
| T8 | Upload longer than 2 hours is not cut | Partially automated | `DestinationTests.sessionIsReportedBeforeAnyByteAndChunksAreAligned`; `DestinationTests.transientChunkFailureProbesAndResumesFromServerOffset`; `DestinationTests.resumeUploadContinuesFromProbe`; `ResumableAndCapTests.offsetThatNeverAdvancesFailsTransiently`; `ResumableAndCapTests.restoredStateCountsAfterRestart` | Real 2-hour upload to Drive ([M0-3](./spikes/m0-3-google-drive-behaviour.md)). |
| T9 | Ten camera and eight screenshots, then an eleventh camera: day split at both destinations | Automated | `DayFolderTests.t9EleventhCameraPhotoSplitsTheDayAndScreenshotsDoNotCount` | — |
| T10 | Change N, then "Sắp xếp lại": the reported file count is correct | Automated | `DayFolderTests.t10ResortReportsTheNumberOfFilesItMoves` | — |
| T11 | Change the system timezone: archive timezone is kept | Partially automated | `ConfigurationAndRecoveryTests.settingsAndArchiveTimeZonePersistAcrossRestarts`; `SchemaAndAssetTests.creationDayUsesArchiveTimezone`; `ModelsAndCodecsTests.archiveDayParsingAndTimezone` | No test changes the system timezone. Owner: change it in System Settings and check a new day folder. |
| T12 | Edit after changing the capture date: edited file sits beside the original | Automated | `EditGateTests.t12TheEditedFileLandsBesideTheOriginalEvenAfterTheDateChanged` | — |
| T13 | Edit, edit again, favourite, album, revert: one edited file per kind | Automated | `EditGateTests.t13EditEditAgainFavoriteAndRevertKeepOneEditedFile`; `SidecarTests.aFavoriteOnlyRefreshesTheSidecarsAndAnUnchangedOneIsNotUploadedAgain` | — |
| T14 | Disk full: watermark stops backfill; running export is cancelled | Partially automated | `DiskAndPowerTests.t14LowDiskStopsBackfillAndClassificationButIncrementalContinues`; `DiskAndPowerTests.t14CriticalDiskStopsEverythingIncludingIncrementalAndClassification`; `DiskAndPowerTests.t14ExportRunningWhenDiskTurnsCriticalIsCancelledWithoutCountingAsAnError`; `ResourceGuardTests.criticalWatermarkStopsEverythingAndCancelsRunningExports`; `DiskGuardPolicyTests` | Filling a real volume ([M0-1](./spikes/m0-1-icloud-export-disk.md)). |
| T15 | Unplugged or Low Power Mode: backfill stops, incremental continues | Partially automated | `DiskAndPowerTests.t15OnBatteryStopsBackfillButIncrementalContinues`; `ResourceGuardTests.powerAndThermalGatesApplyToRateLimitedWorkOnly` | Real power and Low Power Mode changes (on device). |
| T16 | `kill -9` at each step: no duplicate, no loss, no `.part`, no split folder | Partially automated | `CrashRecoveryTests.crashAtEveryUploadStep`; `CrashRecoveryTests.crashDuringExportLeavesNoStagingGarbageAndExportsAgain`; `OrganizationCrashTests` (five tests) | Tests inject faults at named points; no test kills a process. Owner: `kill -9` at each step. |
| T17 | Lid closed or machine suspended at each step | Partially automated | `LocalRecoveryTests.crashingAtEveryStepLeavesNoPartFileNoDuplicateAndNoSplitFolder`; `CrashRecoveryTests.destinationCrashesAfterTheCreateEffect` | No test suspends the Mac. Owner: real sleep and wake. |
| T18 | Network or NAS flaky: no job moves to deferred or skipped | Automated | `UploadErrorTests.t18FlakyDestinationNeverDefersOrSkipsAnyJob`; `UploadErrorTests.transientErrorsRetryInsideThePassWithoutCostingAnAttempt`; `LocalSafetyTests.unmountedVolumeIsOffline`; `LocalRootStateTests.missingVersusOffline` | Real NAS or Wi-Fi flaps (optional). |
| T19 | Root or month folder trashed: stop and ask. Folder deleted for good: recreate and report | Automated | `DestinationTests.rootTrashedOrMissingPausesAndIsNeverRecreated`; `IntegrityAndRootTests.aTrashedRootPausesTheDestinationAndIsNeverRecreatedByTheEngine`; `IntegrityAndRootTests.aFolderThatAnswersNotFoundIsRecreatedAndItsFilesAreMarkedMissing`; `LocalRootStateTests.deletedFolderResolvesToRootMissing` | Trash in the Drive UI ([M0-3](./spikes/m0-3-google-drive-behaviour.md)). |
| T20 | Files deleted at destination, then "Kiểm tra ngay": correct count | Automated | `IntegrityAndRootTests.t20DeletedFilesAreCountedAndOnlyUploadedAgainAfterTheOwnerConfirms`; `LocalMetadataTests.integrityFindsMissingSizeAndBitRot` | Button in Settings on a real destination. |
| T21 | Google access revoked | Partially automated | `AuthSessionTests.missingKeychainItemMeansReauth`; `AuthSessionTests.persistent401BecomesUnauthorized`; `OAuthClientTests.invalidGrantRequiresReauth` | Revoke in the Google account settings and check the app status. The app-side status has no unit test. |
| T22 | Google account changed | Partially automated | `AccountChangeTests.beginKeepsOldAccountLiveAndCommitSwaps`; `AccountChangeTests.discardLeavesOldAccountAndBlocksCommit`; `AccountChangeTests.signInDuringRefreshKeepsTheNewAccount` (Drive package). The `sub` comparison that decides a change is in [AppModel+Account.swift](../PhotoVault/App/AppModel+Account.swift); the app target has no tests. | Owner: sign in with a second account on a test destination and check the recovery prompt. |
| T23 | Photo deleted on iPhone: backup remains | Automated | `ScanAndChangeTests.deletedAssetOnlyGetsDeletedAtAndBackupStays` | Delete on an iPhone signed in to iCloud (on device). |
| T24 | Three signed rebuilds: no new permission prompt, bookmark still works | Partially automated | `KeychainQueryTests.queryTargetsThePrivateDataProtectionKeychain`; `LocalSafetyTests.bookmarkRoundTrip` | Tests run unsigned. Owner: signed rebuilds with a Personal Team ([M0-4](./spikes/m0-4-signing-sandbox-and-filesystems.md)). |
| T25 | Root renamed | Not covered | None. `DriveRootService.rename` calls `renameRoot` ([DriveRootService.swift](../PhotoVault/Services/DriveRootService.swift), [GoogleDriveDestination+Root.swift](../Sources/PhotoVaultDrive/GoogleDriveDestination+Root.swift)), but no test checks that the root ID and its children survive. | Owner: rename in the app and check Drive ([M0-3](./spikes/m0-3-google-drive-behaviour.md)). |
| T26 | NAS offline 3 days: Drive still receives, staging does not grow, NAS catches up within the rate limit | Automated | `OfflineDestinationTests.t26OfflineNasForThreeDaysThenCatchesUpWithRateLimit`; `LocalSafetyTests.unmountedVolumeIsOffline` | Real NAS offline for three days (optional). |
| T27 | Per-destination rules: provisional `camera` that becomes `saved` reaches the `saved`-only destination | Automated | `RulesAndLayoutTests.t27ProvisionalCameraBecomesSavedAndReachesSavedOnlyDestination`; `ClassificationEligibilityTests.globalCeilingAndsWithRules` | — |
| T27b | RAW+JPEG when Drive rejects RAW; Live Photo with two concurrent exports does not jam | Automated | `RulesAndLayoutTests.t27bRawJpegWhenDriveRejectsRaw`; `RulesAndLayoutTests.t27bLivePhotoWithTwoConcurrentExportsDoesNotJam`; `ClassificationEligibilityTests.rawPairPrimaryAndRules` | — |
| T27c | NAS added with `newOnly` after Drive is full | Automated | `RulesAndLayoutTests.t27cNasNewOnlyAddedAfterDriveIsFull`; `ClassificationEligibilityTests.destinationAddedLaterWithNewOnlyGetsOnlyLaterAssets` | — |
| T28 | Đà Lạt: place name. Two provinces: no name. Import: name removed | Automated | `PlaceNameTests.t28DaLatDayIsNamedAtEveryDestination`; `PlaceNameTests.t28TwoProvincesGiveNoNameAndAnImportDropsAnExistingName`; `PlaceNamingPolicyTests.daLatWithIphoneAndRawWithoutGpsIsNamed` | Real geocoder answers ([M0-6](./spikes/m0-6-geocoder-quality.md)). |
| T29 | Zalo and Safari images go to `Saved`; drone video never does | Automated | `ClassificationEligibilityTests.rule3OnlyForPhotosWithoutRaw`; `ClassificationEligibilityTests.chatAlbumNeedsExactMatch`; `RulesAndLayoutTests.screenshotsAndSavedLandInTheirBranches` | Real Zalo and Safari files ([M0-5](./spikes/m0-5-exif-and-header-classification.md)). |
| T30 | Sidecar JSON correct per destination; external or Lightroom `.xmp` not overwritten; regenerated after edit | Automated | `SidecarTests.sidecarContentDiffersPerDestinationAndMatchesTheBuilder`; `SidecarTests.aForeignSidecarIsNeverOverwritten`; `SidecarTests.aSidecarModifiedOutsideTheAppIsNotWrittenOver`; `SidecarBuilderTests.jsonIsByteIdenticalAcrossRunsAndAlbumOrder` | Owner: a real Lightroom-owned `.xmp` next to a backup (on device). |
| T30b | Two edits within a minute during upload: destination ends with the last version | Automated | `EditGateTests.t30bTwoEditsWithinAMinuteWhileUploadingEndWithTheLastVersion`; `EditGateTests.t30bAnEditRaisedWhileTheJobIsUploadingIsNotLost`; `JobTransitionsTests.editDuringUploadIsNeverLost` | — |
| T31 | Database deleted: restored, nothing uploaded again, views not shuffled | Partially automated | `RecoveryTests.t31LostDatabaseIsRecoveredFromDriveWithoutUploadingAnythingAgain`; `LocalRecoveryTests.t31LostDatabaseIsRecoveredFromTheFolderTree` | No test checks view stability after recovery. Owner: delete a real database and compare the Drive and NAS trees. |
| T32 | Library rebuilt: assets reattached by cloud ID | Automated | `ReconciliationTests.t32RebuiltLibraryReattachesByTheCloudIdLearnedByTheBackfill`; `ScanAndChangeTests.unknownLocalIdIsReattachedByCloudId` | Real library rebuild ([M0-2](./spikes/m0-2-change-history-and-identifiers.md)). |
| T33 | Foreign file at NAS: `(conflict-…)` name, foreign file untouched | Automated | `LocalWriteTests.foreignOriginalGetsConflictNameAndIsUntouched` | Real NAS and SMB share ([M0-4](./spikes/m0-4-signing-sandbox-and-filesystems.md)). |
| T34 | `IMG_0001` vs `img_0001`; Vietnamese names in NFC | Automated | `NamingAndLayoutTests.normalizesToNFC`; `NamingAndLayoutTests.collisionSuffixIgnoresCase`; `PlacementAndStatTests.caseInsensitiveCollisionAndPlacementFixedOnce` | — |
| T35 | By device: shortcut opens the right file; follows rename and merge | Automated | `ViewTests.t35ByDeviceShortcutsOpenTheRightFileAndFollowRenameAndMerge`; `ViewRulesAndDiffTests.byDeviceHonoursMergedGroupAndRename` | Open the shortcut in Drive ([M0-3](./spikes/m0-3-google-drive-behaviour.md)). |
| T36 | Geocoding at most 20 requests per minute; day-folder cells first | Automated | `PlaceNameTests.t36GeocodingStaysUnderTwentyRequestsPerMinuteAndDayFolderCellsGoFirst` | Real CLGeocoder rate ([M0-6](./spikes/m0-6-geocoder-quality.md)). |
| T37 | Favourites: on, off (trashed), owner deletes | Automated | `ViewTests.t37FavoritesCreateTrashAndRespectTheOwner`; `ViewRulesAndDiffTests.favoritesAcceptsAnyCategory` | Trash in the Drive UI ([M0-3](./spikes/m0-3-google-drive-behaviour.md)). |
| T38 | By place: Vietnam and Japan; no GPS; language change renames folders only | Automated | `ViewTests.t38ByPlaceGroupsByCountryAndProvinceAndIgnoresAssetsWithoutGps`; `PlaceNameTests.changingTheLanguageRenamesTheFolder`; `ViewRulesAndDiffTests.byPlaceUsesEnglishKeysAndDisplayNames` | Real Vietnam and Japan geocodes ([M0-6](./spikes/m0-6-geocoder-quality.md)). |
| T39 | Views off, on, rebuilt; deleting a view folder does not stop Drive | Automated | `ViewTests.t39SwitchingViewsOffAndOnAndRebuildingAfterTheOwnerDeletedAFolder`; `ViewTests.aShortcutTheOwnerDeletedIsNotCreatedAgainUntilRebuild` | Real Drive folder deletion ([M0-3](./spikes/m0-3-google-drive-behaviour.md)). |
| T40 | Month folder trashed while running: found at next write; "Khôi phục giúp tôi" restores it | Automated | `IntegrityAndRootTests.t40ATrashedMonthFolderIsFoundAtTheNextWriteAndUntrashingRestoresIt`; `IntegrityAndRootTests.untrashingTheRootHelpsToo`; `LocalRootStateTests.folderMovedToTrashIsNotFollowedOrRefreshed` | — |
| T41 | Two instances: the second one refuses to run | Automated | `InstanceLockTests.t41SecondInstanceIsRefused`; `InstanceLockTests.lockIsReleasedWhenTheHolderGoesAway` | Launch two app copies (optional). |
| T42 | Long Vietnamese name on SMB is cut by bytes | Partially automated | `NamingAndLayoutTests.truncatesByBytesAtGraphemeBoundary` | Byte limit on a real SMB share ([M0-4](./spikes/m0-4-signing-sandbox-and-filesystems.md)). |
| T43 | Mac off for more than a week during an upload: IDs checked first, no duplicate file | Partially automated | `CrashRecoveryTests.t43MacOffForAWeekWithAnOpenSessionReusesTheReservedId`; `CrashRecoveryTests.interruptedSessionIsResumedWhenItIsStillOpen` | Simulated time and fake Drive. Owner: a real week off ([M0-3](./spikes/m0-3-google-drive-behaviour.md)). |

Totals (47 rows, 43 spec IDs): **Automated 33**, **Partially automated 13**, **Manual 0**, **Not covered 1** (T25). 46 rows have at least one automated test.

## [VERIFY] items for the owner

Spec tags a default as `[VERIFY]` until a spike or an official source confirms it. The code uses the spec default. Each spike file has a Results table to fill in. Each decision file records the current default and the trigger that reopens it.

| Spike | Spec items (line in spec) | Owner question | Decisions to update |
|---|---|---|---|
| [M0-1](./spikes/m0-1-icloud-export-disk.md) | Volume for the library and watermark metric (§8.5, l. 465) | Does Photos reclaim disk after export? Which free-space value matches the watermark? | [0015](./decisions/0015-disk-guard-watermarks.md) |
| [M0-1b](./spikes/m0-1b-resource-bytes-and-mapping.md) | RAW and video resource mapping (l. 158) | Exact bytes and UTIs of `.ARW`, `.NEF`, `.CR3`, `.DNG`, and DJI files | [0012](./decisions/0012-photos-adapter-defaults.md) |
| [M0-2](./spikes/m0-2-change-history-and-identifiers.md) | Deleted-asset change details (l. 111); Shared Library and Shared Albums (l. 126–127); `.adjustmentData` in Optimize mode (l. 217); cloud-ID stability and length (l. 389); album changes (l. 311) | Change history on expiry, cloud IDs across rebuild and sign-out, adjustment data and album change signals | [0012](./decisions/0012-photos-adapter-defaults.md) |
| [M0-3](./spikes/m0-3-google-drive-behaviour.md) | `pvAssetId` 124-byte limit (l. 200); session lifetime and `Authorization` header (l. 208); revisions kept about 30 days (l. 219); `files.get` after "already exists" (l. 221); quota and shortcuts under `drive.file` (l. 230, 335); My Drive item limit (l. 337); `pvSchema` visible after reinstall (l. 560) | Drive behaviour for resumable upload, IDs, shortcuts, quota, and listing after reinstall | [0013](./decisions/0013-drive-defaults.md), [0016](./decisions/0016-daily-upload-cap-700gb.md), [0017](./decisions/0017-token-bucket-lanes.md) |
| [M0-4](./spikes/m0-4-signing-sandbox-and-filesystems.md) | Bookmark after SMB remount or reboot (l. 274); Personal Team lifetime and entitlements (l. 366–367) | Bookmarks across remount and reboot; signing lifetime; `network.server` entitlement | [0014](./decisions/0014-local-nas-defaults.md), [0009](./decisions/0009-sandbox-container.md), [0010](./decisions/0010-keychain-class.md) |
| [M0-5](./spikes/m0-5-exif-and-header-classification.md) | Header-only classification (l. 139); screen-recording subtype (l. 133); QuickTime make and model (l. 178) | How many bytes classification needs; EXIF and QuickTime field reads | [0012](./decisions/0012-photos-adapter-defaults.md) |
| [M0-6](./spikes/m0-6-geocoder-quality.md) | Structured geocoder fields and country-only fallback (l. 286); location services not needed (l. 368) | Which fields `CLGeocoder` returns; whether it works without Location Services | [0019](./decisions/0019-place-naming-edge-choices.md) |

Not tied to a spike:

| Spec item | Current behaviour | Where recorded |
|---|---|---|
| macOS 27 metadata: `prefetchAssetExtendedMetadata`, caption and keywords (l. 106, 301) | Not compiled against this SDK; sidecars write `"extendedMetadata":"unavailable"` | [0006](./decisions/0006-macos-27-apis-unavailable.md) |
| digiKam sidecar naming `file.ext.xmp` (l. 308) | Documented as a known limit | Owner check; [README](../README.md) |
| Device model names in `device-names.json` (l. 341) | Table entries are unverified; owner can rename groups in Settings | [0019](./decisions/0019-place-naming-edge-choices.md) |

## Not covered, and why

- **T25 root rename.** The code path exists, but no test calls `renameRoot`. A test needs a fake that keeps the root ID and its children, plus an owner check on Drive.
- **T22 account change, app side.** The Drive package tests the account swap itself (`AccountChangeTests`). The decision to treat a new `sub` as a change lives in the app target, which has no test target. Moving that comparison into `PhotoVaultDrive` would make it testable.
- **Real-world legs** (real iCloud library, real Drive and NAS, signed builds, power and sleep). These need the owner's machine and accounts. The agent cannot run them.

## Owner run order

1. Run the M0 spikes in the order of [spikes/README.md](./spikes/README.md). M0-1 has a 25-hour wall time, so start it first.
2. Run the Manual and Partially automated rows marked above, then fill in the Results tables of the spike files.
3. For each default a spike changes, update the matching file in [decisions/](./decisions/README.md).
