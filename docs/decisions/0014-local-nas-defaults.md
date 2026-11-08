# 0014 Local and NAS defaults for unverified filesystem and bookmark behaviour

- **Status:** Pending M0 (M0-4)
- **Spec refs:** FR-70, FR-73, FR-74, FR-75, FR-76, §8.9.4, [VERIFY] markers at FR-75, FR-73 (`RENAME_EXCL`, `F_FULLFSYNC`)
- **Review trigger:** after the owner runs M0-4 on APFS, exFAT and SMB ([spikes](../spikes/m0-4-signing-sandbox-and-filesystems.md))

## Context

The spec marks these filesystem and bookmark behaviours as unverified (`[VERIFY]`). The implementers chose the defaults below so the code can be built and tested.

## Decision

| # | Default in the code | Location | Spike |
|---|---|---|---|
| 1 | Placement tries `renameatx_np(RENAME_EXCL)`. If that is unsupported (`ENOTSUP`, `EINVAL`, `ENOSYS`), it tries `linkat` and then removes the `.part`. Only if both are unsupported and the caller holds the folder write lock does it fall back to check-then-rename. The data fsync tries `F_FULLFSYNC`, then `fsync` on `ENOTSUP`, `ENOTTY` or `EINVAL`. The SMB read-back is best-effort. | `DirectoryHandle.swift` (`renameExclusive`), `AtomicFileWriter.swift` (`flush`) | M0-4 |
| 2 | A security-scoped bookmark is created with `.withSecurityScope` and is resolved with `.withoutUI`. Its behaviour across remount and reboot is untested. | `RootAccess.swift` (`makeBookmark(for:)`) | M0-4 |
| 3 | SMB server-side symlinks cannot be detected by the client. | README known limits | M0-4 |
| 4 | A stale bookmark that cannot be refreshed becomes `bookmarkInvalid`. A missing volume becomes `unavailable(offline)`. | `RootAccess.swift`, `LocalFolderDestination.swift` (`status(for:)`) | M0-4 |
| 5 | A symlinked `.photovault` or `.photovault/tmp` pauses the destination with `rootMissing`. | `LocalFolderDestination.swift` (`status(for:)`), `DirectoryHandle.swift` | M0-4 |
| 6 | The conflict suffix is the first six hex characters of the content SHA-256. `<stem> (conflict-xxxxxx).<ext>`. A retry lands on the same name. | `LocalPath.swift` (`conflictName`) | none (internal) |
| 7 | Replacing an edited or sidecar file is refused unless `expectedPriorHash` matches the on-disk hash (`foreignModified`). | `LocalFileOps+Write.swift` (`replace`) | M0-4 |
| 8 | The check that two roots do not share one `destination.json` id belongs to the engine. | engine (Phase 09/10) | none |

## Consequences

- On a filesystem without `RENAME_EXCL` and without hard links (possible on some SMB and exFAT setups), a file can be placed by check-then-rename. That step is safe only under the folder lock in the app. A process outside the app can still race it (FR-73 TOCTOU, README known limit).
- Item 2 decides whether the NAS must be re-chosen after a reboot (FR-75). M0-4 measures it.
