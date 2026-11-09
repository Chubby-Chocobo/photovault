# Fix: engine organization + hardening findings

Verify: `swift test --scratch-path .build-org --filter "PhotoVaultEngineTests|PhotoVaultCoreTests"` gives 434 tests in 65 suites, all passing. Each new test was also run with its fix switched off and failed (recorded below).

## Per finding

| Finding | Change | Tests (all fail without the fix) |
|---|---|---|
| C1 | `IntegrityChecker.run` skips a destination that is paused for `rootMissing`, `rootTrashed` or `folderTrashed`, or whose root `checkRoot` is not `.ok`. It is reported in `skippedDestinations`. The Drive check moved to the new `IntegrityDrive.swift`. A file under a trashed ancestor is `underTrashedFolder` and is never marked missing; a file the owner trashed in a healthy folder still is. `IntegrityChecker.healMissing` runs after `RootProblemService.recheck` (`.ownerRestored`) and after `untrashAppItems`. It lists the account, probes the rest, and sets present files back to `done` and view-dirty. | `IntegrityRootStateTests`: `aTrashedRootIsSkippedAndNothingIsMarkedMissing`, `aDestinationPausedForItsRootIsSkippedToo`, `aMissingRootIsSkipped`, `filesUnderATrashedFolderAreNotCountedAsMissing`, `aFileTheOwnerTrashedInAHealthyFolderIsStillMissing`, `restoringTheRootHealsMissingFilesWithoutWaitingForTheNextCheck`, `untrashingTheAppItemsHealsMissingFiles`, `healingLeavesFilesThatAreReallyGoneMissing` |
| I1 | New `ViewRebuildPreparation.swift`, used by `ViewStage.prepareRebuild`. It forgets view folders that are gone (as before). It also lists the account and resets `done`/`movePending` shortcuts that are gone (listing, then probe) to `trashed` with no id, so the sweep recreates them. `failed` rows are made `done` if the shortcut still exists, or recreated if not. Any probe or list error makes the rebuild wait. | `ViewRepairTests`: `rebuildRestoresDeletedFoldersAndShortcutsWithoutAnIntegrityCheck`, `rebuildRestoresASingleDeletedShortcutInAnExistingFolder`, `rebuildMakesAFailedShortcutAgainAndKeepsShortcutsThatStillExist` |
| I2 | `ViewExecutor.finishTrashes` returns a `Result` and sends errors through `handle(.trash)`. Anything but `.completed` stops it. `ViewStage` disables views on `.disabled` and ends the pass on `.stopped` or `.retryLater`, so the cycle is no longer failed. | `ViewRepairTests`: `aTrashThatKeepsFailingDoesNotEndTheCycle`, `aTrashTheDestinationRefusesSwitchesViewsOffInsteadOfFailingEveryCycle` |
| I3 | Strays are only app view shortcuts under the current `driveRootId` (`DriveListing.isUnder(root:)`). No root id means nothing is trashed. | `IntegrityRootStateTests.shortcutsOfAnotherRootInTheSameAccountAreLeftAlone` |
| I4 | `UploadAttempt.landedParent` maps `result.parentIds` to a `remote_folder` row. It is used for a first upload, and the planned parent is the fallback. `UploadCompletion.commit` then queues the move to the day folder. | `UploadResumeParentTests.aResumedUploadRecordsTheFolderItLandedInAndTheFileIsMovedToTheDayFolder` |
| I5 | `GeocodeScheduler.refreshAll` no longer deletes `geo_cache` or requests a sweep. It stores `geo_refresh_since`, and `missing()` treats answers fetched before that moment as due for a new request. `save` marks a cell's assets dirty only when the answer changed. | `PlaceRefreshTests`: `refreshingWithUnchangedAnswersWritesNothingAndKeepsThePlaceView`, `aChangedAnswerUpdatesOnlyWhatFollowsFromIt`. The existing `refreshingPlaceNamesClearsTheCacheAndRenames` still passes. |
| S2 | `DirtyQueue.requestSweep` always resets the cursor to `""`. | `DirtyQueueSweepTests.aNewSweepRequestRestartsARunningSweep` |
| S6 | `DescriptionStage.refresh` writes `""` when no part is left and a description was recorded before. Nothing is written if none was ever recorded. | `PlaceRefreshTests.descriptionWithNothingLeftClearsTheOldPlace` |

## Files changed
- Engine: `IntegrityChecker.swift` (290 to 198 lines), `IntegrityDrive.swift` (new), `RootProblemService.swift`, `ViewStage.swift`, `ViewExecutor.swift`, `ViewRebuildPreparation.swift` (new), `UploadAttempt.swift`, `GeocodeScheduler.swift`, `DescriptionStage.swift`, `DirtyQueue.swift`.
- Test support: `FakeDestination.swift`:
  - an item inside a trashed folder reports `trashed`, as on Drive;
  - `resumeUpload` lands in the folder the session was opened for;
  - a public `Item` init;
  - `listsWholeAccount`, off by default, for tests that need account-wide listing.
- Tests (new): `IntegrityRootStateTests`, `ViewRepairTests`, `UploadResumeParentTests`, `PlaceRefreshTests`, `DirtyQueueSweepTests`.
- `ViewDiff.swift` and `ViewPlanner.swift` were not needed.

## Left or needing a change outside my files
- Language change (the mild case of I5): `PlaceNamer.noteLanguage` is not in my file list. It still requests a sweep at once and falls back to English names until the display-language answers arrive.
- `RecoveryTriggers.hasBackupFiles` counts any item with the app schema, so the root folder itself would count if `list(under: nil)` returned it. With the fake's whole-account listing turned on, an empty destination is flagged "has backup data". I kept `listsWholeAccount` off by default for that reason. Please check whether the real root carries the schema property.
- The `ExportPassFailureTests` failure from the first run came from another session's files and disappeared on later runs.

Status: DONE_WITH_CONCERNS
Summary: C1, I1 to I5, S2 and S6 are fixed, each with a test that fails without its fix, and the engine and core suites pass (434 tests). The language-change path (`PlaceNamer`) and a possible root-schema issue in `RecoveryTriggers` are outside my files.
