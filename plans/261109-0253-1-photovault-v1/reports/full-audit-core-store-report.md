# Full audit: PhotoVaultCore + PhotoVaultStore

Branch `review/full-codebase-audit` (= release/0.1.0 head `451f1c3`). I read every file under `Sources/PhotoVaultCore/**` and `Sources/PhotoVaultStore/**`, plus their tests. I followed callers into Engine/App only where I needed them to prove a failure path.

Checks run:
- `swift test --filter 'PhotoVaultCoreTests|PhotoVaultStoreTests'`: 185 tests in 26 suites, all passed.
- `sqlite3` reproduction of finding C1: passed as described below.
- No linter is configured (no swiftlint or swift-format).

Findings already in earlier reports are not repeated here. For example, `VACUUM INTO` on the main thread was reported in code-review-local-app #7.

## Critical

### C1. A name-stem collision on a non-ASCII filename throws a PRIMARY KEY error and stalls the whole sync cycle
- **Where:** `Sources/PhotoVaultStore/AssetPlacementRepository.swift:19-29`.
- **The bug:** `substr(norm_stem, 1, ?)` is bound to `baseKey.count`.
  - Swift `String.count` counts grapheme clusters.
  - SQLite `substr` counts Unicode code points.
  - When the stem contains a multi-scalar grapheme, the prefix is too short, so `taken` comes back empty. Examples: a flag 🇻🇳, a skin-tone emoji 👍🏽, Indic or Thai vowel marks. `NameSanitizer` keeps all of these; it only strips `Cf`.
  - `uniqueStem` then returns `base`, and the `INSERT INTO name_alloc` fails with `UNIQUE constraint failed`.
- **Reproduced:**
  - Swift `"undated_ảnh 🇻🇳".count == 13`, but SQLite `length() == 14`.
  - `substr(…,1,13) = key` returns 0 rows.
  - The second insert fails with `UNIQUE constraint failed: name_alloc…`.
- **Impact:**
  - `PlacementAllocator.place` runs inside `FinalizePass.runAfterScan` and `placeLeftovers`. Those passes write 500 assets per transaction (`FinalizePass.swift:31-37,55-61`). It also runs inside the per-change `ChangeTracker` transaction.
  - The error rolls back the batch and propagates out of `cycle()` (`SyncCoordinator+Cycle.swift:133`) before export and upload.
  - Every later cycle hits the same batch. For the owner's whole library, no new asset is placed, exported or uploaded, and the incremental change token stops advancing.
- **Trigger:** two assets in the same category and day with the same `base`. The most likely case is two undated assets with the same emoji, Indic or Thai filename. Two assets captured in the same second with the same filename also trigger it.
- **Tests:** they use only ASCII stems (`PlacementAndStatTests.swift:8-81`).
- **Fix:** `substr(norm_stem, 1, length(:key)) = :key`, or `norm_stem = :key OR (norm_stem > :key || ' (' AND norm_stem < :key || ' )')`. Add a test with `"…🇻🇳"` and `"…क्षि"` stems.

## Important

### I1. FR-52 "corrupt DB → newest backup + FR-51" is not wired, and `restoreNewest` destroys the live database before it has a good copy
- **Not wired:** `DatabaseBackup.restoreNewest` (`DatabaseBackup.swift:46-59`) has no production caller; only tests use it.
  - `AppEnvironment.swift:93-99` turns any `Store.open` failure into "Không mở được cơ sở dữ liệu" and stops.
  - The spec says (FR-52): "DB hỏng → bản sao gần nhất + FR-51". This is not implemented.
- **Destroys the live database:** once wired, the API is unsafe.
  - Each loop iteration first deletes `databaseURL`, `-wal` and `-shm` (lines 49-52), and only then tries the candidate.
  - If every candidate fails, it returns nil. The original database and its WAL are gone, including committed reservations made after the newest backup.
  - The same happens when the open failed for a transient reason (ENOSPC, permission, lock) and the database was actually fine.
- **Weak validation:** `Store.open` succeeding is the only check (line 54). There is no `PRAGMA integrity_check`, so a torn backup is accepted. SQLite does not fsync `VACUUM INTO` output.
- **Fix:**
  - Move the live files aside (`photovault.sqlite.corrupt-<ts>`) instead of deleting them.
  - Run `quick_check` or `integrity_check` on each candidate before accepting it.
  - fsync the backup after `VACUUM INTO`.
  - Call `restoreNewest` from the launch path when the error is SQLite corruption (`SQLITE_CORRUPT` or `SQLITE_NOTADB`) only.

### I2. `deferredSince` and `stateReason` carry over into a new deferral, so the 30-day expiry fires at once
- **Where:** `Sources/PhotoVaultCore/Rules/JobTransitions.swift:138-141` (`retryDeferred`), `:191-195` (`reinstate`) and `:203-207` (`deferJob` keeps an existing `deferredSince`). The check is in `DeferredJobSweeper.swift:16`.
- **Too-large scenario:**
  1. A job is `deferred(tooLargeForDisk)` at T0. It is outside the 30-day cycle (FR-31).
  2. On day 45 the owner frees space and retries. The job goes to pending, still with `deferredSince = T0`.
  3. Export then fails more than 8 times (iCloud flakiness), so `exportGaveUp` triggers and `deferJob` keeps T0.
  4. The next sweep sees `now - T0 > 30 d` and skips the job (`deferredTooLong`). It gets none of the 24 h retries.
- **Narrowing scenario:** a job is deferred 20 days, then cancelled when the scope narrows, then reinstated months later. Its first deferral expires immediately.
  - `reinstate` also keeps `stateReason`, `lastError` and `mismatchCount`.
- **Fix:**
  - Clear `deferredSince` (and `stateReason`) on `reinstate`.
  - Clear it on `retryDeferred` when the reason was `tooLargeForDisk`, or when the owner asked for the retry.
  - Keep it only for the automatic 24 h retry, which is what "chỉ ghi khi NULL" (spec 8.3) protects.

## Suggestion

### S1. `AssetRepository.fetch(hashPrefix:)` cannot use an index
- **Where:** `AssetRepository.swift:114-118`.
- **Problem:** `substr(asset_key_hash, 1, ?) = ?` ignores index `asset_key_hash`. Every `h:` lookup during recovery (`RecoveryMatcher.swift:136`) scans the whole `asset` table, so recovery is O(N × hashed files).
- **Fix:** use a range: `asset_key_hash >= :p AND asset_key_hash < :p || 'g'`. The column is lowercase hex.

### S2. Dead Store APIs whose behaviour differs from what production uses, and whose tests cover only the dead copy
- **`AssetPlacementRepository.recountDay`** (`AssetPlacementRepository.swift:40-54`):
  - It counts hidden assets, non-pick burst frames and videos regardless of the settings.
  - Its `COALESCE(placement_day, creation_day)` cannot use an index.
  - Production uses `EngineQueries.recountDay`, which applies FR-19 correctly.
- **`AssetRepository.fetchMissingCloudId`** (`AssetRepository.swift:121-125`): it has no cursor, so it would return the same first 500 cloud-less assets forever. Production uses `CloudIdBackfill`'s own paged SQL.
- **Phantom coverage:** `DayStatTests` tests the dead `recountDay`.
- **Also:** `DayStatRepository.swift:5`'s doc comment points to the wrong function.
- **Fix:** delete both, or make them the single implementation.

### S3. `ViewDiff` handles `failed` shortcuts inconsistently
- **Where:** `Sources/PhotoVaultCore/Policies/ViewDiff.swift:49-60`.
- **Problem:** `.failed` is treated like `.done`.
  - Trash and move of a failed shortcut are retried on every pass, with no limit. Each retry spends metadata-lane tokens.
  - A failed create is never retried (same target and parent means no operation).
  - The `> 8 → failed` cap set in `ViewExecutor.swift:255` therefore only stops creates.
- **Fix:** decide what `failed` means and enforce it the same way for trash, move and create.

### S4. `ViewRules` drops hidden and deleted assets from `byPlace` only
- **Where:** `ViewRules.swift:59-60` filters `deletedAt` and hidden for `byPlace`. `devicePath` and the favorites path (`:41`, `:50`) do not.
- **Effect:** deleting or hiding a backed-up photo trashes its "By place" shortcut but keeps its "By device" and "Favorites" shortcuts.
- **Spec:** FR-12 ("Asset bị xoá → chỉ ghi deleted_at") argues for keeping all three.
- **Fix:** apply the same filter (or none) in all three rules.

### S5. The ` (edited)` suffix is not reserved in `name_alloc`
- **Where:** `NameStemBuilder.swift:59-61` with `AssetPlacementRepository`.
- **Scenario:** asset A has stem `…_IMG_1` and gets the edited file `…_IMG_1 (edited).HEIC`. Asset B was imported from a file named `IMG_1 (edited).HEIC` in the same second and day, so its stem is `…_IMG_1 (edited)` and its original is `…_IMG_1 (edited).HEIC`. Both land in the same folder.
- **Effect:**
  - Local: whichever file is written second becomes a conflict copy or `skipped(foreignFile)`.
  - Drive: two files with the same name.
- **Likelihood:** low, but FR-42 promises unique names.

### S6. The disk guard resumes all exports as soon as free space is at or above critical
- **Where:** `DiskGuardPolicy.swift:58-86`.
- **Problem:** hysteresis is applied only to rate-limited exports. Spec 8.5 says "Chạy lại khi ≥ low + 5 GB" right after the critical rule.
- **Effect:** when free space hovers near 5 GB, incremental exports start, get cancelled at the 256 MB checkpoint, and restart. After 2 cancels FR-31 marks ordinary files `tooLargeForDisk`.
- **Fix:** confirm with the owner whether the resume threshold applies to critical too.

### S7. `PlaceNamingPolicy` bounding box breaks across the antimeridian
- **Where:** `PlaceNamingPolicy.swift:144-149`.
- **Problem:** a min/max longitude box puts lon 179.99 and -179.99 about 40,000 km apart.
- **Effect:** day folders in Fiji or Chukotka are always `unnamed`.
- **Severity:** cosmetic.

## Verified sound
- **Job state machine (`JobTransitions`):**
  - Every state has an exit: uploading through startup/FR-44, deferred through the sweep, skipped, cancelled and missingRemote through owner or eligibility.
  - `targetGen`/`doneGen` are kept across `contentChanged` while uploading (a refresh follows).
  - `uploadSucceeded` uses the captured `uploadingGen`.
  - The mismatch cap and remote-id retention match spec 8.3.
  - `upsert` is idempotent. A concurrent-upsert test exists.
- **`readyToUpload`:** the SQL mirrors `isReady`, so the LIMIT is applied after a correct filter.
- **`NameSanitizer`:** NFC, forbidden and control characters, `Cf` stripped, byte-limit truncation at grapheme boundaries, trailing dots and spaces removed, and `.`/`..` become `_`.
  - Stems always start with a date or `undated_`, so reserved device names cannot occur in file names.
- **Day, timezone and DST:**
  - Stem prefix, placement day and `since` scope all use the archive timezone.
  - At a DST fall-back, duplicate local seconds get ` (n)`.
  - Placement is fixed once, and `archiveDay(in:)` prefers the placement day.
- **Layout:** logical paths contain no display names, and view keys are sanitized (so `/` in an admin area is safe).
- **Sidecars:**
  - XMP escapes all five markup characters and strips XML-illegal and `Cf` characters.
  - `|` in album titles becomes `/`.
  - JSON escapes controls, U+2028 and U+2029.
  - Output is deterministic (sorted keys and sets, fixed number format, POSIX `DateFormatter`, no generation time).
- **`CategoryClassifier`:** rule order and the exact trimmed, case-insensitive NFC album match follow FR-20 and spec 8.10. Videos and RAW are never rule 3. The "both Make and Model missing" semantics are correct.
- **`ResourcePlanner`:** FR-21 and FR-72 ceilings, RAW detected by UTI, and the view-target fallback is correct.
- **`ErrorClassifier`:** follows spec 8.14. 401, invalid_grant, quota and offline are destination level; repeated 5xx or 429 back off the destination; checksum and rejected items are item level.
- **Rate limiting:** `TokenBucket` (lanes, debt, clock skew), `RollingByteCap` (sliding 24 h) and `Backoff` (full jitter, cap) are correct.
- **Schema:**
  - Indexes cover the hot paths: job state per destination, job by asset, resource by staging state, and placement-day / creation-day recounts.
  - Destination remove and reset delete `upload_intent`, `upload_job`, `remote_folder`, `move_job` and `shortcut` by `destination_id`.
  - There are no foreign-key cascades that could delete asset history.
  - Migrations are GRDB-tracked, and a backup is taken before a pending migration.
- **Durability:** `synchronous=FULL` and `fullfsync` are applied to the writer after GRDB's own defaults.
- **Concurrency:**
  - `Store` is `Sendable` over a GRDB writer, and repositories are stateless.
  - `ExportControl` is lock-protected, and its checkpoint callback runs outside the lock.
  - Placement allocation is serialized by the writer, and a concurrent test exists.

## Metrics
- Core and Store tests: 185 passed, 0 failed.
- Lint: no linter configured.
- Coverage gaps:
  - No non-ASCII stem collision test (C1).
  - No test for "all backups bad" or "live DB preserved" on restore (I1).
  - No test for `deferredSince` after a tooLarge retry or after cancel/reinstate (I2).

## Unresolved questions
1. Spec 8.5: does "Chạy lại khi ≥ low + 5 GB" also apply after a critical stop (S6)?
2. Should deleted or hidden assets keep their view shortcuts (S4)? The spec does not say.

Status: DONE
Summary: One Critical: a placement name collision on stems with multi-scalar characters (SQLite code points vs Swift graphemes) throws a UNIQUE error that halts every sync cycle. Two Important: FR-52 restore is unwired and the restore API deletes the live database before it has a good copy; deferral timestamps carry over and cause an immediate 30-day skip. Seven suggestions; everything else in Core and Store checked out.
