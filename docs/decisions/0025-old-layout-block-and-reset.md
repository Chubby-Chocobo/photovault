# 0025 Upgrading from 0.1.0: block the old layout, start over with a factory reset

- **Status:** Accepted
- **Spec refs:** FR-117 and FR-118 (new), FR-08, FR-51, §8.7 (amended)
- **Review trigger:** the owner wants a real migration of old backups, a second layout change, or a user reports the block on a database that is not from 0.1.0

## Context

Decision 0023 changed the layout from `camera/YYYY/MM` to one folder per day, and said updating means starting over. Running 0.2.0 on a 0.1.0 database showed what that leaves open:

- The database still holds `camera/YYYY/MM` parents. A sidecar refresh queued moves of the re-uploaded sidecars into `Camera Uploads/YYYY-MM-DD` while their originals stayed in month folders.
- A 0.1.0 root reused after a reset is adopted on Drive (`RemoteInventory` reads the `pvLogical` folders and queues one move per file) and ignored on a NAS (`LocalTreeInterpreter` does not know year folders, so everything is exported again beside it).

The owner's rule is "resync, not migrate": the app never moves or deletes backup data at a destination.

## Decision

- **The old database is blocked, not converted.** On first use `LegacyLayout.isBlocked` looks for any `upload_job.remote_logical_parent` or `remote_folder.logical_path` that matches `(camera|screenshot|saved)/YYYY` or below (0.1.0 stored `camera/2026/11`; the current layout stores `camera/2026-11-08`, which never matches). The answer is stored once in `kv.legacy_layout` (`1` or `0`). While it is `1`: the cycle ends with `blocked(.legacyLayout)` before any check, startup recovery does nothing, and commands that would write jobs or moves throw `EngineError.legacyLayout`. The snapshot's overall state is `legacyLayout`.
- **The owner sees why and what to do.** The menu bar shows a red card (no notification, nothing repeats), Sync now is disabled, and the card opens Settings › Nâng cao (Advanced), where the "Đặt lại từ đầu…" (Start over…) section moves to the top while the block holds.
- **Factory reset is the exit.** It signs out of Google, writes a marker file and relaunches; the new process takes the instance lock (waiting up to 15 seconds for the old one), empties the data folder before the database opens, then removes the marker last, so a crash finishes at the next launch. It keeps the interface language and `drive-daily-cap.json` (Google counts the daily limit per account, not per database). If the app cannot relaunch itself it says the reset finishes on the next launch. Nothing at a destination is touched. The new database is fresh, so it is not blocked.
- **An old root is not reused.** `LegacyRootProbe` reads folder names one level deep: a four-digit folder at the root, or under `Screenshots` or `Saved`. Onboarding, add destination, account change and root change run it on each found root (Drive: `childFolders`; NAS: `childFolderNames`, only when `.photovault/destination.json` exists) and show "this is a 0.1.0 backup" with the choices: move it to the Trash, pick another folder, or create a new root. Recovery repeats the test on its full listing and returns `notReady(.legacyLayout)` before writing anything, so no other path can adopt such a root.
- **Documentation.** The README has an "Upgrading from 0.1.0" section with the steps.

## Alternatives

- Move the old files into day folders: breaks "never moves or deletes", and a 0.1.0 backup can be hundreds of thousands of files.
- Delete the old database on launch: the owner would lose the record that explains why nothing synced, and the app would delete data without asking.
- Keep syncing into the old layout: two layouts in one root, and the owner asked for day folders.
- Only warn: the warning does not stop sidecars being split from their originals.

## Consequences

- An upgrading owner must start over and the library is uploaded again into a new root. The old root stays until the owner trashes it.
- A 0.1.0 database whose jobs were all pending or without folders (no `remote_folder` rows) is not detected; it has nothing at a destination to split. A 0.1.0 database with only undated assets (`camera/unknown`) is not detected either.
- The flag is stored once: a database detected as current keeps working even if old folders appear later. The root probe covers that case at the destination.
