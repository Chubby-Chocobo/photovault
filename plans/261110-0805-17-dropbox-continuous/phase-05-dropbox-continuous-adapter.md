---
phase: 05
title: "Dropbox continuous adapter"
status: pending
priority: P2
size: M
human_effort: 1-2h
dependencies: [01]
touches:
  - Sources/PhotoVaultDropbox/DropboxClient.swift
  - Sources/PhotoVaultDropbox/DropboxClient+Changes.swift
  - Sources/PhotoVaultDropbox/DropboxModels.swift
  - Sources/PhotoVaultDropbox/DropboxContentHasher.swift
  - Sources/PhotoVaultDropbox/DropboxListingMapper.swift
  - Sources/PhotoVaultDropbox/DropboxChangeCompactor.swift
  - Sources/PhotoVaultDropbox/DropboxImportSource.swift
  - Sources/PhotoVaultDropbox/DropboxContinuousSource.swift
  - Tests/PhotoVaultDropboxTests/DropboxContinuousSourceTests.swift
  - Tests/PhotoVaultDropboxTests/DropboxContentHasherTests.swift
  - Tests/PhotoVaultDropboxTests/DropboxTestSupport.swift
acceptance:
  - swift test --filter "DropboxContinuousSourceTests|DropboxContentHasherTests"
  - swift test --filter Dropbox
---

# Phase 05: Dropbox continuous adapter

## Overview
This phase adds `DropboxContinuousSource: ContinuousSource` over the existing client and auth, with the root guard, net-state compaction and a streaming content hash. Size M: one module and a known API, with no schema change. It runs in parallel with phases 02–04.

## Context
- Client:
  - `listAll` follows cursors but drops the last one: `Sources/PhotoVaultDropbox/DropboxClient.swift:59-69`.
  - `probeFolder`: `:72-74`. Download by path or `id:`, with a chunk callback: `:86-112`.
  - Retries: `:144-168`. The 409 mapping handles only `path/not_found`: `:172-179`.
- Entries lack `content_hash`, and the `deleted` tag is unhandled: `Sources/PhotoVaultDropbox/DropboxModels.swift:3-28`.
- Path mapping (folder casing, hidden names, supported types, NFC): `Sources/PhotoVaultDropbox/DropboxImportSource.swift:89-135`.
- Dropbox facts:
  - Deleted entries carry `path_lower`, `path_display` and `name`, and no `id` ([forum](https://www.dropboxforum.com/t5/Dropbox-API-Support-Feedback/How-do-i-differentiating-between-deleted-files-and-updated-files/m-p/387558)).
  - `continue` fails with `reset`, and the app must call `list_folder` again ([forum](https://dropboxforum.com/discussions/101000014/409-reset-error-for-list-foldercontinue-api-from-business-endpoint/285996)).
  - After a folder rename, `continue` fails `not_found` or `reset` (audit C1 links).
  - Entries must be processed in order (audit M5).
  - `content_hash` is the SHA-256 of the concatenated SHA-256s of 4 MiB blocks (Dropbox content-hash reference; the test uses the published example vector).
  - Whether a deleted folder also lists its children, and the exact shape after a root rename, are `[UNVERIFIED]`. Both shapes are handled.

## Requirements
1. Models: `DropboxListEntry` decodes `content_hash`, and `deleted` entries (with no id) decode. Add `get_metadata` for folders, returning the id, and `not_found` as a typed result.
2. `DropboxClient+Changes.swift`:
   - `listWithCursor(path:recursive:) -> (entries, cursor)` keeps the final cursor; `listAll` calls it.
   - `listChanges(cursor:)` follows `has_more`. A 409 whose `error_summary` starts with `reset` throws an internal `CursorReset`.
   - `folderId(path:) -> String?` returns nil for `not_found`.
3. `DropboxContentHasher`: an incremental block hasher. `download` feeds it every chunk, and the result goes in a new `DropboxDownload { file: ExportedFile, contentHash }`. The import adapter ignores the hash.
4. `DropboxListingMapper`: extracted from `DropboxImportSource.list()`, with the same output for imports. `DropboxImportSourceTests` stay unchanged and green.
5. `DropboxChangeCompactor`: walks entries in feed order and keeps the net state per `path_lower`. A `deleted` entry drops the earlier entries at or under its path and is **always** emitted as `.tree`, even when a later file entry takes the same path; that later file entry is kept too. The planner turns "removal of an id listed again" into a move (case-only rename) and "another id now at this path" into removed + reuse, so no deletion is lost (re-audit I-2).
6. `DropboxContinuousSource` (`id`, `rootPath`, `rootId: String?`, `client`, `scratchDirectory`, `metadata`):
   - `probe()`: when `rootId` is set, `folderId(root)` must equal it. A different id or `not_found` throws `rootChanged`; with no `rootId` (whole Dropbox) it uses `probeFolder("")`.
   - `changes(since: nil)`: root check, then a full recursive listing with `isComplete = true`.
   - `changes(since: c)`: `listChanges(c)` with `isComplete = false`.
     - On `CursorReset`: root check, then a full listing.
     - On 409 `not_found`: the root check decides between `rootChanged` and `unavailable`.
   - Mapping:
     - A `deleted` entry whose `path_lower` equals the root or is an ancestor of it throws `rootChanged`, and nothing is returned.
     - Other deleted entries under the root become `.tree(pathKey: path_lower)`.
     - Files become `RemoteFile` (`remoteId = id`, `pathKey = path_lower`, `contentHash = content_hash`, `client_modified`, `server_modified`, size, uti). A file with no `id` or `content_hash` is skipped.
     - Folder entries produce nothing.
   - `inspect(remoteId:)`: downloads by id to scratch and returns SHA-256, metadata and `contentHash` (from the hasher). Scratch is removed afterwards.
   - `exportResource`: needs `locator.remoteId` (else `fileMissing`) and downloads by id. A 409 `not_found` runs `probe()` first.
   - No log line carries a path, id, cursor or email.

## Implementation steps
1. Write the red tests with the stub transport (canned `list_folder`, `continue`, `reset`, `deleted`, `get_metadata` bodies in `DropboxTestSupport.swift`).
2. Models, client additions, hasher, mapper extraction (run the import tests), compactor, adapter.

## Tests
- `DropboxContentHasherTests`: the published example vector; inputs below, at and above 4 MiB; chunk boundaries that do not line up with blocks.
- `DropboxContinuousSourceTests`:
  - Listing: first listing over two pages (complete, cursor kept).
  - `continue` with:
    - an added file;
    - a modified file (new `content_hash`, same id);
    - a move (deleted old path + file with the same id);
    - a case-only rename (deleted + file with the same `path_lower`);
    - a file listed and then its folder deleted later in the same delta (the file is gone);
    - a delete and a new file with another id at the same path in one delta (both the `.tree` and the file are emitted);
    - a folder deleted and recreated with new files in one delta (the `.tree` and the new files are emitted);
    - deleted file and folder (`.tree` keys).
  - Root guard:
    - `reset` runs the root check, then a complete relist;
    - root id changed or missing → `rootChanged` on probe, `changes` and after `reset`;
    - a `deleted` entry for the root or its parent → `rootChanged`.
  - Filtering: hidden and unsupported files are skipped; non-ASCII names are NFC.
  - Errors: 401 refreshes once; revoked → `accessRevoked`; 429/5xx → `busy`; network → `unavailable`.
  - Downloads: export by id; a missing `remoteId` → `fileMissing`; `inspect` returns the content hash of the bytes served.
  - The log sink sees no path.

## Risks and rollback
- The mapper extraction and the download change touch the shipped import adapter. Mitigation: a pure extraction, with the import tests unchanged.
- Unknown: shared folders and team spaces (`Dropbox-API-Path-Root`) are out of scope and documented as a limit.
- Rollback: revert the module changes.
