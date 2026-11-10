# Plan audit: Dropbox continuous source (#17 round 3)

Plan: `plans/261110-0805-17-dropbox-continuous/` (plan.md + phases 01–07). Code checked on `feat/17-dropbox-continuous` @ `0c528f1`; #27 plan checked in `photovault-27-split-day-by-place`. The plan's file:line references are accurate (spot-checked ~30). No code was run; this is a design audit.

What was checked and holds: the old and new versions of a modified file never share a destination name. `name_alloc` is never pruned, so the new version gets `stem (1)` (`Sources/PhotoVaultStore/AssetPlacementRepository.swift:22-30`). The revive path brings a retired `x:` asset back under a new `local_id` (`ImportIngest.swift:26-34`). Writing the cursor with the last batch and computing complete-listing removals before batching is sound. The `x:` key with no `RemoteIdIndex` is the right call.

## Critical

### C1. Replacing, renaming or deleting the root can mass-delete
- **Scenario A (root recreated).** The owner renames `/Camera Uploads` to `/Camera Uploads 2025`. The phone app then recreates `/Camera Uploads` on its next upload. Dropbox cursors are tied to the path ([forum: continue fails `path/not_found` after a rename](https://dropboxforum.com/discussions/101000014/getting-409-error-when-calling-list-foldercontinue-on-renamed-folder/394310); [forum: `reset` and restart](https://www.dropboxforum.com/t5/API-support/Handling-renamed-folders-in-list-folder-list-folder-continue/m-p/225665)).
  - `continue` returns `reset` (or `not_found`, and the next probe succeeds against the new folder).
  - The adapter then does a full relist of the new, nearly empty folder with `isComplete = true` (phase 05 req. 4).
  - The planner marks every unlisted row removed and retires every asset: pending jobs are cancelled, later destinations skip all of them, and views and day counts churn.
  - The plan's guard, "root missing → `unavailable`" (phase 03 req. 4, phase 05 `probe()`), never fires because the path exists.
- **Scenario B (root deleted).** The delta contains a `deleted` entry whose `path_lower` equals the root. Phase 05 maps "deleted entries under the root" to `.tree`, and the planner's rule (`remotePath == key` or prefix `key/`) removes every row. Whether the root's own entry counts as "under the root" is not specified.
- **Plan changes:**
  1. Phase 05: store the root folder's `id` at add time (`get_metadata` of the path; whole Dropbox `""` has none) in `SourceConfig`. Check it on `probe()` and before any complete listing. If the id differs, throw `unavailable` (new reason `rootChanged`) and remove nothing.
  2. Phase 05: a `deleted` entry equal to the root, or above it, is never turned into `.tree`. It becomes `unavailable`, and the cursor is not committed.
  3. Phase 03: add a mass-removal brake in the engine. When one feed would remove more than max(50 rows, 20 % of live rows), hold the source offline (reason `rootChanged` or `largeRemoval`), commit nothing, and show it in the UI with an explicit owner action. The planner stays pure; the stage checks the counts.
  4. Tests: a fake `replaceRoot` (same path, new folder) followed by `expireCursor` must remove 0 rows; a delta with `.tree(root)` must remove 0 rows; a large legitimate folder delete must trip the brake.

### C2. An asset is retired while another live row still holds its bytes
- `SourceAssetRetirement` (phase 03 req. 6) and `removeContinuousSource` (phase 04 req. 6) mark the asset deleted even when its bytes are still present in a watched or imported source:
  - **In-source copy.** The same photo exists at `/A/x.jpg` (the asset's primary) and `/B/x.jpg`, which became a `duplicate` row (`ImportStage+Drafts.swift:64-68`). Deleting `/A/x.jpg` retires the asset; `/B/x.jpg` stays in Dropbox but is no longer backed up.
  - **Surviving companion.** In a RAW+JPEG pair the RAW is the primary (FR-112). An owner who deletes RAWs to save space and keeps the JPEGs gets the asset retired. The JPEG's pending job is cancelled (`EligibilityService.recompute`, `EligibilityService.swift:43-52`), so it is never uploaded if it was still pending, and a destination added later never receives it.
  - **Across sources.** The file is copied from `/Camera Uploads` (source A) into `/Photos/2025` (source B, a sibling, which the guard allows). B's row becomes a `duplicate` of A's asset. Later the owner cleans out Camera Uploads, and A retires the asset that B still holds. The same happens when A is removed, and for a one-time import whose rows were duplicates of A's assets.
- The rule "a file deleted in Dropbox marks its asset deleted" (acceptance 2) does not hold here: the photo was not deleted from any source.
- **Plan change (phase 03 `SourceAssetRetirement`, reused by `removeContinuousSource`):** after an asset is marked deleted, move every other live `import_item` of an open source with `asset_key = K` (`imported` non-primary rows and `duplicate` rows) back to `pending`. Give them a group key with a suffix and `seen_at = NULL`. The next ingest either revives K under that row (no upload: done jobs stay) or ingests the companion on its own. Add three test cases: in-source copy, RAW deleted with JPEG kept, cross-source copy then delete. Record Photos-deleted assets matched by a continuous `duplicate` row as a known limit, or apply the same hook in `ChangeTracker.swift:90-99`.

## Important

### I1. Batching can apply actions out of order, and `stem (n)` can hit the primary key
- **Order.** The plan is computed once, then applied in chunks of 500 (phase 03 req. 4). Nothing fixes the order of actions across chunks.
  - Example: a `reuse` of path *p* (which assumes *p*'s row is removed in the same plan) lands in chunk 1, and the `removed(p)` lands in chunk 2.
  - Chunk 1 resets the still-live row to the new id. Chunk 2 then marks that row (now the new file) removed and retires the old asset.
  - The new file is never ingested, and Dropbox will not report it again.
- **Primary-key collision.** The known subset holds only "every file's lowercased path" (phase 03 req. 4). Choosing `stem (2).ext` cannot see an existing row already at `stem (2).ext`. `insertRemote` is a plain insert, so `(source_id, rel_path)` violates the primary key, the transaction throws, and the same feed fails on every poll: the source is stuck.
- **Plan change:** apply in a fixed order: removed → changed → moved → returned/reuse → insert. Make each apply step compare-and-set on `(rel_path, expected remote_id, state)`. Choose free `stem (n)` paths inside the transaction from a prefix query, or fetch candidates with `rel_path` prefix `stem (`. Add tests: more than 500 mixed actions, and an existing `IMG (2).jpg` row.

### I2. A stale inspect retires the asset it just created
- `inspect(remoteId:)` downloads the current bytes, but the row keeps the hash seen by the feed.
- If the file changes between the feed and the read:
  1. Asset K2 is built from the new bytes, while `remote_hash` still holds H1.
  2. The next feed reports H2, and the planner emits `changed(supersedes: K2)`.
  3. K2 is retired and its pending uploads are cancelled.
  4. The row waits out the 1 h delay, is downloaded again, and K2 is revived.
- The reverse case: a file modified after ingest but before export fails with `fileChanged` → `.permanent(.resourceMissing)` (`ExportWorker+SourceFailures.swift:25`, `ErrorClassifier.swift:61`).
- **Plan change:** make `inspect` also return the provider hash of the bytes it read. Dropbox `content_hash` is SHA-256 over 4 MiB block hashes and can be computed while streaming. The group commit then stores that hash as `remote_hash`. Alternatively read by `rev:`. Add a test where the bytes change between feed and inspect: no retire, no second download.

### I3. The settle delay can split pairs
- Phase 02 applies `readyBefore` to both the inner and the outer query of `nextGroups` (`ImportItemRepository.swift:38-44`). A group whose members were seen in different polls is offered partially.
- A Live Photo or RAW+JPEG that arrives across two polls is committed as two assets.
- **Plan change:** decide readiness for the whole group (`GROUP BY group_key HAVING MAX(COALESCE(seen_at, 0)) <= ?`), and have the outer query return all pending members. Add a test.

### I4. Failed rows of a continuous source are never retried
- After FR-124's give-up, a group is marked `failed`, and the remedy is that the owner "imports again".
- A continuous source has no re-import. With an unchanged hash the planner emits no action, even on a complete listing.
- Result: the photo is silently never backed up; only a count shows it.
- **Plan change:** retry `failed` rows of open continuous sources on a slow schedule (for example daily, after a complete listing, and on sign-in), or add a **Thử lại** action on the row. Add a test.

### I5. The migration name and the rollback claims are wrong after #27
- **Rename.** The plan renames `v7-continuous-sources` to `v6-…` at merge. #27 adds a newer-schema guard: `hasBeenSuperseded` makes `Store.open` throw (#27 phase 01). Any database that ran a branch build would no longer open, including the owner's real library during the manual E2E. Without the guard, the renamed migration would run its `ALTER TABLE ADD COLUMN` again and fail with "duplicate column".
- **Rollback text.** "An older build ignores the columns" is false once #27 lands.
- **0.4.0 behaviour.** "0.4.0 treats a continuous row as an open import" is also false. 0.4.0 cannot decode `status = 'watching'` or `state = 'removed'`: `RowDecoding.parse` throws `corruptRow` (`RowDecoding.swift:16`). `SourceRepository.fetchAll` and therefore every cycle and snapshot fail, which stops Photos backup too.
- **Plan change:** use an id without a number (for example `continuous-sources`), registered after whatever is on the base at merge, and never renamed once any build ran it. Rewrite the Rollback section: downgrading after use breaks the app, and a newer schema is refused. Run the owner E2E only on a build with the final migration id, or on a copy of the data folder.

### I6. The "a modified file is a new asset" cost assumption needs the owner
- "Modifications are rare" holds for Camera Uploads. It does not hold for a watched whole Dropbox or a working folder where tools write metadata in place (Lightroom or digiKam keywords, phone editors that save over the file).
- Every touched file is downloaded twice, uploaded again as a new asset, and the old one is marked deleted. The archive can double in size with no warning.
- The decision says "Review later: yes" but was not put to the owner.
- **Plan change:** present it per `review-audit-self-decision.md`, with three options:
  - (a) as planned;
  - (b) as planned, plus a per-poll threshold that holds the source and asks the owner (for example more than 50 changed files);
  - (c) treat changed files as a new version but keep the old asset live, not deleted.

### I7. Background downloads ignore the network and power rules
- `pauseOnExpensiveNetwork` and `allUploadsOnlyOnACPower` gate uploads only (`SyncCoordinator+Cycle.swift:71-78`). `ImportStage` reads with no such check.
- One-time imports are started by the owner. A continuous whole-Dropbox source downloads every file twice in the background, including over a phone hotspot.
- **Plan change:** phase 04 `ingestContinuous` returns `false` while `uploadsAllowedNow()` would be false. Optionally the feed listing gets the same gate. Add a test.

### I8. The remove-source semantics are the planner's choice, not the owner's
- Removing a source deletes every asset of the source. Cancelling a one-time import keeps finished assets live for later destinations (FR-115, decision 0026 keeps grants for exactly that reason).
- Combined with C2, removing A also drops files that other sources still hold.
- The owner's wording, "Gỡ: stop watching; what is backed up stays", does not settle whether later destinations should receive those files.
- **Plan change:** put the two options from the plan's own Decisions section to the owner before phase 04. If "keep live" wins, keep the grant (as for imports) and drop the `resourceMissing` rule for cancelled continuous sources.

## Minor

- **M1.** SQLite `LIKE` ignores ASCII case, but the contract says `pathKey` is "compared exactly" (phase 01). A future S3 provider would remove `/Photos/x` along with `/photos/x`. Use `substr(remote_path,1,length(?)) = ?` or `GLOB`. Also, SQLite `lower()` folds ASCII only, so the "lowercased path" lookup misses Vietnamese case collisions ("ẢNH.jpg" vs "ảnh.jpg"). Fold in Swift, or store a folded-key column.
- **M2.** `returned` goes through `pending`, the 1 h wait and a re-download for every file. Moving a folder out and back, or a large move that Dropbox reports across two polls, downloads everything again. When `remote_hash` is unchanged and the row kept `asset_key`, revive in the feed transaction instead (so `markRemoved` must keep `asset_key` and `is_primary`).
- **M3.** Keychain grants can be orphaned. A crash between `removeContinuousSource` and the grant delete, or between the token copy and `addContinuousSource`, leaves an `import-<id>` item. Sweep at launch: delete `import-*` items whose row is missing or is a cancelled continuous row.
- **M4.** `cancelImport` and `resumeImportAfterSignIn` accept any open, non-Photos source (`SyncCoordinator+Imports.swift:43,63`). Guard `cancelImport` with `mode == .oneTime`, so a continuous row cannot be "finished" without unregistering its adapter.
- **M5.** Dropbox says delta entries must be processed in order; the planner uses unordered set semantics. Specify in the contract that adapters return the net state, compacted in feed order per `path_lower`. Without that, a file listed and then deleted with its folder later in the same delta stays live. That fails safe, but the row is stale and its exports fail later.
- **M6.** The 5-minute recheck runs "while a continuous source has pending rows" (phase 06 req. 9). That includes rows waiting out the 1 h delay, so about 12 idle full cycles run per hour. Use the snapshot's `ready` count instead.
- **M7.** An export-side `holdSource` (download fails) is cleared by the next successful `changes` call. If the download host fails while the API host answers, the source flips between offline and watching on every poll. Keep the export hold until a download succeeds, or note it as accepted.
- **M8.** Acceptance 6 says "no re-upload". The sidecar source block takes its name and path from the new source, so revived assets may upload their sidecars again. Say "no original re-uploaded" or assert that the sidecar bytes are unchanged.
- **M9.** The cycle stops entirely when Photos access is lost (`SyncCoordinator+Cycle.swift:103`), so Dropbox sources stop too. Document it (spec FR-130 and the README).
- **M10.** `removeContinuousSource` "deletes the rest in one `UPDATE`". That skips `DirtyQueue` and view marking, unlike the per-asset path used in `cancelImport`. Use the per-asset path or state why views do not need it.
- **M11.** YAGNI: `.item` removals have no producer until OneDrive. Keep the case, since it is cheap, but limit tests to one case. The provider table in phase 07 is fine as long as it stays marked `[UNVERIFIED]`.

## Test matrix additions (summary)

- Root replaced or deleted, with and without `reset`.
- Large-removal brake.
- Retire hand-over: in-source copy, RAW deleted with JPEG kept, cross-source copy and remove-source.
- More than 500 mixed actions; an existing `stem (2)` row.
- Bytes changed between feed and inspect.
- Split-poll pair with the settle delay.
- A failed group retried on a continuous source.
- Expensive network.
- Migration id stability with the #27 guard.
- Case-only rename (`deleted` entry with the same `path_lower`), and Unicode case collision.
- Shared folder unmount and remount (revives, no upload).
- Export fails `resourceMissing`, then the file returns: the job must be re-armed.

## Unresolved questions

- Owner: should a modified file supersede (delete) the old asset, and should removing a source drop its files for later destinations (I6, I8)?
- Does Dropbox return a `deleted` entry for the listed root itself, or only `reset`/`not_found`? C1 handles both, but the adapter tests need the real shape (owner E2E: rename the watched folder).
- Should a deletion in Photos re-queue continuous `duplicate` rows (the C2 hook in `ChangeTracker`), or is that a documented limit?

Counts: Critical 2 / Important 8 / Minor 11

Status: DONE_WITH_CONCERNS. The plan is not ready to implement until C1, C2 and I1 are folded into phases 01–05, and I5, I6 and I8 need owner answers or plan text changes.
