# Full audit: Local / NAS destination

Branch `review/full-codebase-audit` @ 451f1c3. Scope: `Sources/PhotoVaultLocal/**` (15 files, ~1.4k LOC) and `Tests/PhotoVaultLocalTests/**`. I read every file and every syscall, and checked the engine and app callers wherever they decide how severe a finding is.

**Checks I ran**
- `swift test --filter PhotoVaultLocalTests` (scratch build path): 53 tests in 7 suites passed. Another session has uncommitted Drive/Photos edits in this worktree; nothing under `PhotoVaultLocal` is modified.
- C probes on APFS and on HFS+, exFAT and FAT32 disk images.
- A scratch Swift package linking the real `PhotoVaultLocal`, used to reproduce findings I2, I3 and S1 end to end.
- Probes and package: `/private/tmp/claude-501/-Users-annh-workspace-photovault/c95079e8-f124-4c29-8253-08dccc3843e6/scratchpad/audit-local`.

**Overall:** No Critical findings. Nothing in the module deletes, truncates or overwrites an owner file, apart from the locked check-then-rename window on external processes, which the spec accepts. Six Important findings are availability and NFR-01 defects that earlier rounds did not cover.

## Important

**I1. `readdir` errors are ignored, so a listing can come back truncated without any error.**
- Where: `DirectoryHandle.swift:103`. `readdir` returns NULL at end of directory and also on error. `errno` is never reset before the loop or checked after it.
- Scenario: on SMB, a `getdirentries` call fails partway with ETIMEDOUT, EIO or ESTALE. `entries()` returns the names read so far, and `walk` / `list` reports success.
- Effects:
  - `RecoveryTriggers.hasBackupFiles` (`RecoveryTriggers.swift:57`) can miss existing backups, so a re-added NAS folder is treated as empty.
  - `RecoveryService` (`:173`) and `RemoteInventory` (`:62`) match against an incomplete tree, so files are re-exported (rate-limited Photos/iCloud work). Where the layout changed, files are re-uploaded beside the existing copies.
  - The sweep misses orphans (harmless).
- Fix: set `errno = 0` before each `readdir`. On NULL with `errno != 0`, throw `ErrorClassifier.destinationError(errno:)`.

**I2. One owner file whose name is longer than 255 UTF-8 bytes makes every listing of the destination fail.**
- Where: `LocalPath.swift:13` limits names to 255 *bytes*. `LocalFileOps.swift:123` passes every name from `readdir` through `dir.status(name)`, which validates it and throws.
- Verified: APFS, HFS+, exFAT and FAT32 all accept a 100-character CJK name (300 bytes). In the scratch package, `list(under: nil)` failed with `itemRejected(invalid name)` after 3 items.
- Scenario: the owner keeps a file with a long Vietnamese or CJK name anywhere under the NAS root. Recovery, inventory and the reuse probe then fail on every run until the file is renamed.
- The limit does not protect anything: the app's own names are already capped at 240 bytes NFC (`NameSanitizer.swift:7`).
- Fix:
  - Drop the 255-byte check for names that come from `readdir`, or raise it to the `d_name` capacity (1023 bytes) and let the syscall return ENAMETOOLONG.
  - In `walkDirectory`, skip and log an entry whose `status` or `item` throws, instead of aborting the whole walk.

**I3. An orphan `.part` that cannot be deleted pauses the destination as "root deleted" on every cycle.**
- Where: `LocalFileOps+Support.swift:17` uses `try tmp.unlinkOwned(name)`, which is fatal to `checkRootAndSweep`. `LocalFolderDestination.swift:65` then maps any `itemRejected` to `.paused(.rootMissing)`.
- Verified: an orphan `.part` with `uchg` set makes `checkAvailability()` return `paused(rootMissing)`.
- Real triggers:
  - EPERM/EACCES on a NAS `.part` owned by another SMB user.
  - EBUSY when another client still has the file open. EBUSY hits the `default` branch, so it becomes `itemRejected("errno 16")`.
- Result:
  - `DestinationHealth` writes `rootMissing` on every cycle.
  - `NotificationPolicy.swift:59` sends the "folder deleted/trashed" notification.
  - `HardeningServices` adds an owner decision.
  - Backups to this destination stop.
- The code contradicts its own comment at `AtomicFileWriter.swift:51` ("Failure to remove is not fatal: the orphan sweep retries").
- Fix: `do { try tmp.unlinkOwned(name) } catch { log; continue }` for each file in the sweep.

**I4. `move`, `renameFolder` and `ensureFolder` never flush the directory, so a power loss after the DB commit can produce duplicates (NFR-01).**
- Where:
  - `LocalFileOps+Write.swift:126-128`: `move` returns right after the rename.
  - `LocalFileOps.swift:90-91`: `renameFolder` returns right after the rename.
  - `LocalFileOps.swift:69`: `ensureFolder` does not flush after `mkdirat`.
- Only `upload` and `writeMarker` call `parent.sync()`.
- The DB now commits with `synchronous=FULL` plus `fullfsync`, but that flushes only the app's own disk, not the destination device.
- Scenarios:
  - **File move:** power fails after `MoveCommit.file` is durable but before the external SSD or NAS has persisted the rename. On restart the file is at the old path and the DB points to the new one. The move job is already `done`, so `MoveRecovery` does not run. The integrity check marks the file missing and re-uploads it to the new path, and the old copy stays forever.
  - **Folder rename:** the same sequence re-uploads the whole day folder under its new name.
- Fix: after a successful placement, call `destination.sync()` (and `sync()` on the source directory for cross-folder moves) before returning, just as `upload` does. Do the same for the parent after `mkdirat` in `ensureFolder`.

**I5. Blocking file I/O still runs on the Swift cooperative pool and on the destination actor.**
- Where: `LocalFolderDestination.swift:150` (`list`) and `:162-177` (`quota`).
- `list` runs the whole recursive `walk` inside `Task.detached`, so `readdir`, `fstatat` and `openat` for the entire tree run on a cooperative thread. That is minutes on a 100k-file NAS.
- `quota()` is actor-isolated and calls `access.withRoot` synchronously. That covers bookmark resolution under an NSLock, `RootState` lookups and `URL.resourceValues`. On a hung SMB mount this blocks one cooperative thread and the whole actor, so `upload`, `checkAvailability` and the other calls on this destination cannot even start.
- `BlockingQueue` was introduced to prevent exactly this, but these two entry points bypass it.
- Scenario: the NAS stops responding during recovery or `freeSpace`. The cooperative pool has only about one thread per core, so on a 4-core Mac a couple of stuck walks stall the engine actors for every destination.
- Fix:
  - Run `walk` on `metadataQueue`, bridging into the stream from the dispatch block, and check for cancellation through a flag.
  - Run `quota` through `metadataQueue.run`.
  - Consider capping the concurrent metadata queue's width. Each stuck probe pins a GCD thread from the shared utility pool.

**I6. Renaming or moving the root folder during a backup reports "folder deleted".**
- Where: `RootAccess.swift:74-77` reuses the resolved path for 30 s. `DirectoryHandle.swift:41` turns ENOENT on that path into `RootState.missingError(path:)`, which carries no bookmark UUID. `RootState.swift:33-35` then returns `.rootMissing` for any path outside `/Volumes`, or when `/Volumes/<name>` still exists.
- Scenario: the owner renames `~/Backups/PhotoVault` to `~/Backups/PhotoVault-2024` while uploads run. Within at most 30 s, an operation fails with `rootMissing`. The destination is paused, the "folder deleted/trashed" notification fires, and an owner decision appears. About 5 minutes later the bookmark resolves to the new path and the status goes back to active, but the alarm has already been sent.
- Fix: on ENOENT/ENOTDIR from `openRoot` under a cached lease, retire the lease and resolve the bookmark once more before classifying. Resolution follows the rename, and it already handles trash and UUID-based missing vs. offline.

## Suggestion

**S1. A FIFO at an app path blocks a queue forever. On the bulk queue that stops all uploads to the destination.**
- Where: `DirectoryHandle.swift:117` opens with `O_RDONLY` and no `O_NONBLOCK`, and checks the file type only after `open` returns. `contentHash` (`LocalFileOps.swift:143-145`), `readSmallFile` (`:158-160`) and `currentHash` (`+Write.swift:24-25`) only check that the entry exists, not that it is a regular file.
- `probe` reports a FIFO as `.file` (`LocalFileOps.swift:53`), so `IntegrityLocal` treats it as intact and may sample-hash it. The sample hash goes through `contentHash` on the serial bulk queue.
- Verified: both `readSmallFile` and `contentHash` on a `mkfifo` path were still blocked after 3 s, while a concurrent `probe` returned.
- Fix: add `O_NONBLOCK` to the `openat` in `openFile` (it has no effect on regular files), or require `isRegular` before opening. Have `probe` reject entries that are neither files nor folders.

**S2. Case-only folder renames fail on exFAT.**
- Where: `DirectoryHandle.swift:181`. On exFAT, `RENAME_EXCL` returns ENOTSUP (probed), so `renameFolder` falls back to check-then-rename. `status("HANOI")` then finds `hanoi` itself on the case-insensitive volume, and the rename throws `foreignFile`.
- Probed: APFS, HFS+ and FAT32 perform the case-only rename with `RENAME_EXCL`.
- Fix: if the existing entry has the same `st_dev`/`st_ino` as the source, call `renameat` directly.

**S3. `move` crash recovery adopts any regular file with the target name.**
- Where: `LocalFileOps+Write.swift:119-122`. When the source is gone, any regular file at the target name is accepted as already moved. That includes an owner's unrelated file, if the owner deleted the app's copy.
- Effect: the DB then points at owner content. For originals this heals through the integrity size check, and replace is protected by the prior hash, so no data is lost.
- Fix: compare `st_size` with an expected size passed by the caller.

**S4. Lock coverage gaps (latent).**
- `move` takes a read lock on `commonAncestor` (`LocalFolderDestination.swift:137-138`). A writer strictly below that ancestor does not conflict with it (`FolderLockManager.swift:17-25`). So `renameFolder("camera/2024/05/2024-05-01")` can run during a move out of that folder into `saved/...` (ancestor `""`). Today this only produces a spurious `notFound`, because the handles are fd-relative and `MoveWorker` runs serially.
- `FolderLockManager` belongs to one actor instance (`:14`), while the part registry and the rename memo are process-wide. `repickFolder` swaps in a new instance (`AppModel+Destinations.swift:179,190`) without draining the old one, so their exFAT check-then-rename windows do not exclude each other.
- Fix: for `move`, lock both parents in sorted order. Key the lock managers by root identity.

**S5. A read-only volume flips between `active` and `offline` on every cycle.**
- Where: `checkRootAndSweep` (`LocalFileOps+Support.swift:10-21`) never tests whether the volume is writable, so it reports `.active`. Uploads then fail with EROFS, which maps to `.offline` (`ErrorClassifier.swift:91`).
- Triggers: a disk remounted read-only after fsck, or an NTFS disk. The status shown is "offline" rather than read-only.
- Fix: check `fstatfs` with `MNT_RDONLY` on the root fd in `checkRootAndSweep`.

**S6. The read-back check reads the page cache, not the disk.**
- Where: `AtomicFileWriter.swift:43-46`. After `F_FULLFSYNC` the pages are still in the unified buffer cache, so the read-back hashes cached memory.
- That cannot catch more than the write-time hash at `:36` already caught, yet it costs a full extra read of multi-GB files.
- Fix: set `F_NOCACHE` on the write and read-back descriptors, or record that the check is best-effort (the spec already says so for SMB).

**S7. Small cleanups.**
- `readSmallFile` has no EINTR retry (`LocalFileOps.swift:165-166`). Its loop is a copy of `readMarker`'s loop, which does retry (`+Support.swift:57-65`). Extract one bounded reader.
- `replace` hashes the current file three times (`+Write.swift:88, 93, 101`). `inspect` could return the hash it already computed.

**S8. Test gaps.**
- There is no seam for the `linkat` branch (`DirectoryHandle.swift:170-178`), which is the path every HFS+ external disk takes when `RENAME_EXCL` fails.
- Nothing tests `readdir` failure, names over 255 bytes, a failing sweep, or a non-regular file at an app path.

## Verified sound
- Every `open`/`openat` has `O_NOFOLLOW|O_CLOEXEC`, and directory opens also have `O_DIRECTORY`. Paths are opened one component at a time, after `validate` has rejected empty, `.`, `..`, `/` and NUL.
- Mount-point escapes are blocked by the `st_dev` check. Symlinks are refused at every level.
- No file descriptor leaks on any error path: `openRoot`, `openChild`, `openFile`, `createExclusive`, `entries` (dup/fdopendir), `stage` (out/readBack), `copy`, `testConnection`.
- Nothing truncates (no `O_TRUNC`; `O_EXCL` on create). Deletion only happens through `unlinkOwned` (a UUID `.part` in tmp, or `.photovault-test` at the root), and only for regular files.
- The active-part registry marks a `.part` before creating it, and it is shared by every destination object that uses the same tmp folder.
- `replace` re-checks the prior hash after staging.
- Write order is correct: `F_FULLFSYNC` (falling back to `fsync` on ENOTSUP/ENOTTY/EINVAL), then the rename, then a sync of the parent directory (upload and marker).
- Reads and writes retry on EINTR. Partial writes loop until done.
- Conflict names are deterministic (a hash prefix), so retries are idempotent.
- Hashing streams in 1 MiB chunks. `readSmallFile` is bounded both by `st_size` and by a running count.
- Security-scope start and stop are balanced through the lease reference count. `.withoutMounting` is used. Trash is checked before a stale bookmark is refreshed.
- `VolumeKey` works on non-root folders: `fgetattrlist ATTR_VOL_UUID` returns a UUID for subfolders on APFS, exFAT and FAT32 (probed).
- Rename support matrix (probed):

  | Filesystem | `RENAME_EXCL` | `linkat` |
  |---|---|---|
  | APFS | works | not probed |
  | HFS+ | works | works |
  | FAT32 | works | ENOTSUP |
  | exFAT | ENOTSUP | ENOTSUP, so the memo plus write-locked fallback is used |

  `RENAME_EXCL` also performs case-only renames on APFS, HFS+ and FAT32, and APFS lookups treat NFC and NFD as the same name.
- Locks cannot deadlock: nothing acquires a lock while holding one, `placing` releases before re-acquiring as a writer, and waiters are served in FIFO order. `commonAncestor` is fixed.
- A directory check-then-rename cannot destroy data: renaming over a non-empty directory fails with ENOTEMPTY, and over a file with ENOTDIR.
- The reserved-path check is case-sensitive, but no case variant of `.photovault` can reach it, because top-level folder names are fixed (`DynamicLayout`).

## Plan follow-ups
- Fix I1–I6 before release; I3, I1 and I4 are small changes.
- I did not edit any plan or task state.

## Unresolved questions
- Does macOS smbfs support `RENAME_EXCL` and `F_FULLFSYNC` against Synology/Samba? That decides whether every NAS goes through the fallback, and so how much S2 and S4 matter. I could not test a real share.
- A Samba share with `wide links`/`follow symlinks` resolves symlinks on the server, so the client never sees a link it could reject. Should the README say that the symlink guarantee stops at what the client can see?

Status: DONE
Summary: No Critical findings. 6 Important: readdir errors ignored, the 255-byte name limit aborts listings, sweep failure reports rootMissing, move/rename not flushed (NFR-01), blocking I/O on the cooperative pool and actor, and false rootMissing after a root rename. 8 Suggestions. Findings I2, I3 and S1 were reproduced against the real module.
