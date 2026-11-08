# Code review: PhotoVaultLocal + app layer

Branch `feat/photovault-v1` @ 9433489 (base 7cad755). Scope: `Sources/PhotoVaultLocal/**`, `PhotoVault/**`, `Sources/PhotoVaultAppSupport/**`, checked against the spec FRs.
Checks I ran: `swift test --filter "PhotoVaultLocalTests|PhotoVaultAppSupportTests"` passed (129 tests, 20 suites). I also probed an exFAT disk image with a small C program: `renameatx_np(RENAME_EXCL)` and `linkat` both return ENOTSUP (45). A standalone Swift snippet confirmed that `commonAncestor` returns paths that are not ancestors.

No Critical findings. Nothing in the module overwrites, truncates or deletes an owner file, apart from the replace window in finding 3 and the TOCTOU on the fallback path that the spec accepts. The order of flushing to disk is correct: F_FULLFSYNC on the data, then rename, then a sync of the parent directory.

## Important

1. **Bookmark resolution mounts SMB shares and blocks while it does (breaks FR-70 "Không tự mount SMB").** `RootAccess.swift:45` and `FolderPicker.swift:33` resolve with `[.withSecurityScope, .withoutUI]` and leave out `.withoutMounting`.
   - Every destination operation calls `withRoot`, which resolves the bookmark again (each probe, hash and sweep; the engine's local integrity check probes once per file).
   - For an unmounted share, each call tries to mount it, every 5 minutes and on every probe. `revealInFinder` does this on the main thread.
   - Fix: add `.withoutMounting`. Resolve the bookmark once per batch, not once per file.

2. **A local root moved to Trash or deleted is followed silently, and backups keep going into the Trash.** `RootAccess.swift:53-57`: a stale bookmark is refreshed to wherever the folder now is, including `~/.Trash/…` or `/Volumes/X/.Trashes/501/…`.
   - Nothing in `PhotoVaultLocal` looks for trash. `grep -i trash` finds only `trashed: false`.
   - A deleted root shows up as `.offline` (`DirectoryHandle.swift:35`), not `rootMissing`.
   - Result: `paused(.rootTrashed/.rootMissing)` and the FR-61 "thư mục bị xoá/trash" notification never happen for NAS or local destinations. Emptying the Trash then destroys the whole backup without any warning.
   - Fix: on a stale bookmark, check whether the resolved URL is inside the trash (`FileManager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)` or a `.Trash`/`.Trashes` component). If it is, throw `rootTrashed`. When the folder has moved, compare against `displayPath` before adopting the new location.

3. **The replace path checks the prior hash before a long staging step, so an owner edit made during that time is overwritten (FR-73).** `LocalFileOps+Write.swift:81-89`.
   - It compares the on-disk hash with `expectedPriorHash`, then stages the full new content (copy, F_FULLFSYNC, read-back; minutes for an edited video), then calls plain `renameat`.
   - Any change another app makes to that file during staging is replaced without a check.
   - Fix: stage first, then re-hash and compare immediately before `renameReplacing`, under the write lock. That shrinks the window to the TOCTOU the spec accepts.

4. **On exFAT (and any filesystem without RENAME_EXCL and hard links), every upload is written twice.** `LocalFolderDestination.swift:28-35` combined with `LocalFileOps+Write.swift:54-56`.
   - `placing` runs the whole body under the read lock: full stage, fsync and read-back.
   - Only at the rename does it throw `ExclusiveRenameUnsupported`. The `.part` is then discarded and the whole body runs again under the write lock.
   - I confirmed exFAT returns ENOTSUP for both `renameatx_np(RENAME_EXCL)` and `linkat`, so every upload does double I/O, two full fsyncs and two read-backs, and nothing remembers the result.
   - Fix: cache "exclusive rename unsupported" per destination after the first failure, or keep the staged `.part` and retry only the placement under the write lock.

5. **`LocalPath.commonAncestor` returns paths that are not ancestors, so `move` locks the wrong folder.** `LocalPath.swift:39-44`: the `zip … where x == y` loop never stops at the first mismatch.
   - `("camera/2024/05/01", "camera/2024/06/01")` returns `"camera/2024/01"`. `("saved/2023/05", "camera/2023/05")` returns `"2023/05"`. Both were verified.
   - `move` (`LocalFolderDestination.swift:126`) therefore takes its lock on a folder that does not contain the source or the target. It does not conflict with a `renameFolder` write lock or an upload write lock on the real folders.
   - On the check-then-rename fallback this removes the only in-process guard against `renameat` overwriting a file the app just placed.
   - It is latent today only because MoveWorker and uploads run in separate stages. There is no test.
   - Fix: `break` on the first mismatch, and add a unit test.

6. **The errno mapping turns permanent conditions into retries and makes one bad folder pause the whole destination.** `ErrorClassifier.swift:72-82`.
   - **EACCES/EPERM → `bookmarkInvalid`.** This is destination-level. One read-only subfolder, a file locked on the NAS or an ACL makes the whole destination "Mất quyền truy cập thư mục… chọn lại thư mục". Re-picking passes the marker check and fails again, so it loops. The same error also aborts `walk()` (`LocalFileOps.swift:110` only catches `itemRejected`), which aborts recovery.
   - **EROFS (30), EFBIG (27, files over 4 GB on FAT32), EMFILE/ENFILE, EILSEQ, ENAMETOOLONG → `itemRejected`.** These are item-level, so every job burns its attempts. On FAT32, each attempt re-copies up to 4 GB.
   - A read-only volume (a disk remounted read-only after an fsck, or NTFS) never pauses the destination.
   - `testConnection` on such a volume shows "Lỗi tạm thời. Thử lại sau."
   - Fix: map EROFS to a destination-level status, EFBIG/ENAMETOOLONG/EILSEQ to permanent, EMFILE to transient, and give a per-path EACCES an item-level class.

7. **`VACUUM INTO` runs synchronously on the main thread.** `AppModel.swift:264-268`: `requestSync` is a MainActor Task that calls `backups.backupIfDue` (`DatabaseBackup.swift:24-26`, `writeWithoutTransaction { VACUUM INTO }`) on launch and timer triggers.
   - When `run` returned `.queued` because a cycle is in progress, the main thread also waits for the GRDB writer, and VACUUM then holds the writer and blocks the engine.
   - With a large database the menu bar UI hangs for seconds (NFR-08).
   - Fix: run it in `Task.detached(priority: .utility)` or have the coordinator do it at the end of a cycle.

8. **The onboarding sidebar lets the owner skip every step check (FR-01).** `OnboardingFlow.swift:75-79`: `jump` only requires `target <= furthest`. The sidebar (`OnboardingView.swift:55,73`) allows any step up to the furthest one reached.
   - After reaching step 9, the owner can go back to step 3, clear the root name or type `/`, jump to Start and press Bắt đầu. `createRoot(name: "")` then runs (`AppModel+FirstStart.swift:69-70`).
   - Or the owner can go back to step 7, pick another NAS folder (`testPassed = false`) and jump ahead. That untested folder is committed and gets uploads.
   - Or the owner can press "Dùng tài khoản khác" at step 1 and jump to Start. `start()` returns silently because `identity == nil` (`OnboardingModel.swift:191`).
   - Fix: let `jump` move forward only while `canAdvance` holds for every step in between, or re-check all the conditions in `start()` / `performFirstStart`.

9. **The FR-61 "Checksum lệch" notification can never fire.** `AppModel+Notifications.swift:16-21` fills `mismatches` only from `OwnerDecisionItem.Kind.checksumMismatch`.
   - Nothing creates that kind. `EngineHardeningCommands.swift:70-76` maps every engine decision and has no checksum case. `collectDecisions` adds only rootTrashed and rootMissing.
   - Bit rot found by the scheduled 7-day check is therefore never notified.
   - The manual check's notice (`AppModel+Hardening.swift:39-41`) also ignores mismatches. When only hashes differ, it says "thiếu 0 file".

10. **The integrity interval setting never reaches the engine.** The Advanced tab edits `integrityCheckIntervalDays` (`AdvancedTab.swift:38`, validated as 1-365 days). `needsEngineRecompute` deliberately ignores it (`SettingsForm.swift:79-80`), so no engine call is made.
    - `IntegrityStage` uses the constant `env.tuning.integrityInterval` (7 days; `EngineEnvironment.swift:59`, `IntegrityChecker.swift:196`).
    - A grep finds no engine code that reads `integrityCheckIntervalDays`.
    - Fix: read the value from `env.settings` in `IntegrityStage`.

## Minor

11. **The orphan sweep can delete a `.part` that is still being written.**
    - `AtomicFileWriter.swift:22-23` creates the file before `active.insert`. A concurrent `checkAvailability` sweep (`LocalFileOps+Support.swift:15`, which takes no lock) can unlink it in that gap, and staging then fails with `notFound`. Fix: insert the name before `createExclusive`.
    - The `active` set belongs to one actor instance. `repickFolder` swaps in a new `LocalFolderDestination` (`AppModel+Destinations.swift:184`) while uploads on the old instance may still be running. The new instance's sweep then sees the old instance's `.part` files as orphans.

12. **`IntegrityWalker` and `FolderRenameRecovery` are not used by production code.** `verifyIntegrity` and `recoverRename` have no callers outside the module; the engine uses `IntegrityLocal` and `MoveRecovery`. This is a second, parallel implementation.
    - The walker also keeps one open `DirectoryHandle` per distinct parent (`IntegrityWalker.swift:61-68`). With thousands of day folders it hits the GUI process limit of 256 file descriptors, and later files are reported as `rejected`.
    - Fix: delete both or wire them in; don't keep both copies.

13. **Multi-GB synchronous file work blocks cooperative-pool threads.** The `FolderLockManager.withLock` body (`FolderLockManager.swift:57-60`) and the `Task.detached` calls in `LocalFolderDestination` run copy, fsync and hash work on the Swift concurrency pool.
    - With 2 uploads per destination across several destinations, plus hashing, this can starve the engine actors on low-core Macs.
    - Fix: move the work to a dedicated `DispatchQueue` and resume through a continuation.

14. **Nested destination roots are accepted.** `pickLocalFolder` (`AppModel+Destinations.swift:30-47`) rejects only a marker id that is already known.
    - A subfolder or a parent of an existing destination root is accepted. The outer destination's walk, integrity check and FR-74 recovery then see the inner destination's tree, including its `.photovault`, as content.

15. **First start polls forever.** `waitForScan` (`AppModel+FirstStart.swift:89-96`) has no timeout or cancellation. If the scan stalls (for example, Photos access revoked in the middle), the onboarding window stays on "Quét metadata" with no failure state.

## Plan follow-ups
- Findings 1-10 should be fixed before landing. Finding 5 is a one-line fix plus a test.
- I did not edit any plan or task state.

## Unresolved questions
- Does macOS smbfs support `RENAME_EXCL`? If it does not, finding 4 also affects every NAS destination. I tested only exFAT.
- Do the cycle stages ever run moves at the same time as uploads to the same destination? That decides whether finding 5 is latent or active.
