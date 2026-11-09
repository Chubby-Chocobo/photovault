# Fix: Local/NAS audit findings (Important + S1)

All new tests are in `Tests/PhotoVaultLocalTests/LocalResilienceTests.swift`. "Before" = HEAD sources of `PhotoVaultLocal` plus bare seam stubs so the tests compile; "after" = working tree.

| Finding | Change | Test | Before -> after |
|---|---|---|---|
| I1 readdir | `DirectoryHandle.swift` `entries(reader:)`: `errno = 0` before each call, NULL with `errno != 0` throws via `ErrorClassifier` (EIO -> offline) | `readdirFailureIsNotAShortListing`; guard `staleErrnoDoesNotFailACompleteListing` | no error thrown -> throws `.offline` |
| I2 long owner names | `LocalPath.swift`: `validate(name:)` keeps 255 B for names we create; new `validateExisting` (1023 B) used by `status`, `openChild(create:false)`, `openFile`, `components`, rename source. `LocalFileOps.swift` walk: `describe` per entry, `itemRejected` entries skipped and counted in one log line (no names); other errors still abort | `ownerNamesLongerThanOurLimitAreListedAndProbed` (also asserts upload of a long name is still rejected), `entryThatCannotBeDescribedIsSkippedNotFatal` | list threw `itemRejected(invalid name)` -> lists and probes it |
| I3 sweep | `LocalFileOps+Support.swift` `checkRootAndSweep`: per-file do/catch, counts failures, logs the error kind once, continues | `orphanThatCannotBeRemovedDoesNotPauseTheDestination` (uchg orphan + removable orphan) | `paused(rootMissing)` -> `.active`, removable orphan swept |
| I4 flush | `LocalFileOps.flush(_:)` (dir.sync + test seam `onDirectorySync`). Called after `ensureFolder` (only when it created the folder), `renameFolder`, `move` (destination, and source when different; also on the already-moved path), plus upload/replace/marker now use it | `folderCreationFlushesTheParent`, `folderRenameFlushesTheParent`, `moveFlushesBothFolders` | no flush -> parent(s) flushed |
| I5 queues | `LocalFolderDestination.swift`: `list` walks on `metadataQueue` via new `BlockingQueue.submit`, stops via a cancellation flag set in `onTermination` (walk now takes `isCancelled`); `quota()` runs through `metadataQueue.run` | `listAndQuotaRunOnTheMetadataQueue` (queue label seen inside `withRoot`) | ran off the queue -> label `photovault.local.meta.*` |
| I6 root rename | `RootAccess.swift`: new protocol method `invalidateResolvedRoot()` (default false; bookmark root drops its lease). `LocalFileOps.withRoot`: if opening the root fails with rootMissing/offline and a lease was dropped, re-resolve and retry once (body has not started, so safe) | `renamedRootIsFollowedInsteadOfReportedMissing`; guard `genuinelyDeletedRootIsStillMissing` | `paused(rootMissing)`, 1 resolve -> `.active`, 2 resolves |
| S1 FIFO | `openFile` adds `O_NONBLOCK` (fstat `isRegular` check already follows); `probe` rejects non-file/non-folder with `itemRejected("not a regular file")` | `fifoAtAnAppPathIsRejectedWithoutBlocking` (10 s watchdog, releases the blocked open), `fifoIsNotListed` | contentHash blocked (watchdog fired) -> all three reject immediately |

## Files changed
- `Sources/PhotoVaultLocal/`: `BlockingQueue.swift`, `DirectoryHandle.swift`, `LocalFileOps.swift`, `LocalFileOps+Support.swift`, `LocalFileOps+Write.swift`, `LocalFolderDestination.swift`, `LocalPath.swift`, `RootAccess.swift`
- `Tests/PhotoVaultLocalTests/LocalResilienceTests.swift` (new)

## Verification
- `swift test --scratch-path .build-local --filter PhotoVaultLocalTests` in the worktree currently does NOT build: the other session's `Sources/PhotoVaultEngine/IntegrityDrive.swift:66,149` has an async-in-autoclosure error (and an earlier duplicate `@discardableResult` in `ResourceGuard.swift`). Not mine, not touched.
- Instead I ran the same sources/tests through a scratch package that symlinks `PhotoVaultCore`, `PhotoVaultLocal`, `PhotoVaultTestSupport` and `PhotoVaultLocalTests` (swift-tools 6.1, same settings): 66 tests in 8 suites passed (53 existing + 13 new). Re-run the real command once the Engine compiles.

## Notes / left
- Public API addition: `RootAccess.invalidateResolvedRoot()` has a default implementation, so existing conformers are unaffected.
- The metadata queue width is not capped (audit said "consider"); not done.
- Not touched (outside scope): S2-S8.
- Nothing staged or committed.

Status: DONE_WITH_CONCERNS
Summary: I1-I6 and S1 are fixed with 13 new tests; each fails on the old code and passes now (66/66 in an isolated Local-only package). The worktree-wide `swift test` could not run because the other session's Engine edits currently fail to compile.
