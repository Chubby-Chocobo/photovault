# [VERIFY] defaults reported by implementers

Input for docs/decisions/ and docs/spikes/ (phase 12).

## Phase 05 — Photos adapter
1. Header "absent" only when CGImageSourceGetStatusAtIndex is complete or full file arrived; JPEG without camera make may be read fully (M0-5).
2. Bytes needed on iCloud-only assets, cancelDataRequest completion error, chunks after cancel: unverified, handled defensively (M0-1b, M0-5).
3. Answer known on last chunk: cancel, no completeFile (no total size available).
4. PHPersistentChangeFetchResult iterated as Sequence; currentChangeToken non-optional; unreadable archived token → tokenExpired (M0-2).
5. PHPhotosError integer mapping 3105, 3210, 3164, 3169, 3072, 3310, 3311.
6. Failed cloud-ID mapping results skipped (no deprecated not-found check) (M0-2).
7. burstIsPick true for non-burst; hasAdjustments = .adjustmentData resource present; albums = regular user albums only (M0-2: Shared Library/Albums).
8. Video metadata: synchronous MetadataReading waits ≤ 30 s for AVFoundation load.
9. Cursor format "offset|creationDate|localId".
10. Disk write errors → PhotosSourceError.other.
11. CLGeocoder builds without deprecation warning on macOS 26.5 SDK.

## Phase 07 — Local/NAS
1. exFAT/SMB: linkat fallback, locked check-then-rename fallback, F_FULLFSYNC→fsync fallback and SMB read-back untested (M0-4).
2. Security-scoped bookmark across remount/reboot untested (M0-4).
3. SMB server-side symlinks undetectable by the client (README known limit).
4. Stale bookmark whose refresh fails → bookmarkInvalid; volume gone → offline.
5. Symlinked .photovault or .photovault/tmp → paused(rootMissing).
6. Conflict suffix = first 6 hex of content SHA-256 (retry lands on the same name).
7. replaceContent without expectedPriorHash refused (foreignModified).
8. Cross-root duplicate destination.json id check belongs to the engine.

## Phase 06 — Google Drive
1. drive.file + generateIds(type=shortcuts) and shortcut create/move/trash permission; 403 insufficientPermissions/forbidden → viewsNotPermitted (M0-3).
2. Child trashed flag when parent trashed (parent checks rely on it) (M0-3).
3. 409 for reused ID on files.create and on resumable session start (M0-3).
4. 308 without Range after zero bytes; zero-byte upload `bytes */0`.
5. findRoots by pvRoot after reinstall with drive.file (M0-3).
6. SystemKeychainStore needs a signed host (-34018 unsigned) (M0-4).
7. Session URIs only accepted on https *.googleapis.com.
8. 700 GB = 700×10⁹ bytes.
