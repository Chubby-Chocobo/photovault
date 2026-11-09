---
phase: 07
title: "Local/NAS destination"
status: completed
priority: P1
size: M
human_effort: 3-4h
dependencies: [03]
touches:
  - Sources/PhotoVaultLocal/**
  - Tests/PhotoVaultLocalTests/**
acceptance:
  - swift test --filter PhotoVaultLocalTests
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 07: Local/NAS destination

## Overview
`LocalFolderDestination: Destination` with atomic, never-overwriting writes (FR-73), folder locks and crash-safe renames (8.9.4), security-scoped bookmarks (FR-70/75), `destination.json` (FR-74) and tree integrity walk (FR-76). Size: M — one module, POSIX details.

## Requirements
- Write path: `.photovault/tmp/<uuid>.part` → `fcntl(F_FULLFSYNC)` (`ENOTSUP` → `fsync`) → read back SHA-256 → place: `renamex_np(RENAME_EXCL)` → fallback `link()`+`unlink()` → fallback check-then-rename under the folder lock.
- Same hash already at target → done; different content without app hash → original goes to `<stem> (conflict-xxxxxx).<ext>`, edited/sidecar → `skipped(foreignFile)`; replace edited/sidecar only when on-disk hash equals `job.uploaded_hash`, else `skipped(foreignModified)`.
- Never follow symlinks (`O_NOFOLLOW`, `lstat`); delete only `.part` and `.photovault-test`.
- `Test connection`: write/read/delete `.photovault-test`.
- Folder locks per logical folder: file writes take read lock, renames take write lock (an actor-based RW lock).
- Rename protocol with `move_job` callbacks: inProgress → rename → commit; startup resolution (new exists/old gone → commit; old exists → retry; both gone → integrity flag).
- Availability: bookmark resolve (stale → refresh, failure → `unavailable(bookmarkInvalid)`), offline → `unavailable(offline)`; `quota` from volume capacity.
- Integrity: walk tree, compare path + size, re-hash a 1 % sample capped at 5 GB.

## Implementation Steps
1. Tests in a temp directory: atomic write + no overwrite, foreign file conflict naming, foreign-modified sidecar refusal, symlink refusal, rename crash-recovery states, test-connection file, integrity sample selection.
2. Implement.

## Success Criteria
- [x] Local tests green on APFS temp dir.

## Risk Assessment
- [VERIFY M0-4] `RENAME_EXCL`/`F_FULLFSYNC` on exFAT/SMB and bookmark survival across remount: fallbacks implemented, documented as best-effort.

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- Open the bookmark root once as a directory fd; every operation is fd-relative (`openat` with `O_NOFOLLOW | O_DIRECTORY` per component or `O_NOFOLLOW_ANY`, `renameatx_np(RENAME_EXCL)`, `linkat`, `unlinkat`); `fstat` `st_dev` must match the root. Tests: symlinked intermediate folder, symlinked `.photovault/tmp`.
- Orphan sweep of `.photovault/tmp` on `checkAvailability` (startup, remount): unlink only names matching `^[0-9A-F-]{36}\\.part$` inside the verified tmp fd.
- `destination.json` also stores `archiveTimezone`; adding a folder whose id already belongs to another bookmarked root is refused.
- Availability re-check every 5 minutes (FR-75) is driven by the engine scheduler; the destination exposes a cheap `checkAvailability`.
- README known limit: SMB server-side symlinks cannot be detected by the client.
- Runs `DestinationConformanceSuite` in a temp directory.
