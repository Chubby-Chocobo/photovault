---
title: "Dropbox as a continuous source, and a mechanism for adding providers"
description: "A Dropbox folder (or the whole account) watched through a change feed, ingested through the import pipeline; plus a provider guide for OneDrive, S3 and Flickr"
status: on-hold
priority: P2
size: L
human_effort: 8.5-16.5h
issue: 17
branch: feat/17-dropbox-continuous
tags: [sources, dropbox, engine, schema, ui]
created: 2026-11-10
sources:
  - "tracker: github:Chubby-Chocobo/photovault#17"
  - "context: file:plans/261109-2045-17-multiple-sources/plan.md"
  - "context: file:plans/261110-0435-17-cloud-folder-imports/plan.md"
  - "context: file:plans/261110-0805-17-dropbox-continuous/reports/plan-audit-dropbox-continuous.md"
  - "context: file:plans/261110-0805-17-dropbox-continuous/reports/plan-reaudit-dropbox-continuous.md"
  - "context: file:docs/architecture/continuous-source-extension.md"
  - "spec: file:docs/requirements/photovault-spec-v1.md"
authoritative: "tracker: github:Chubby-Chocobo/photovault#17"
---

# Plan: Dropbox continuous source (issue #17, round 3)

Owner (issue #17): Dropbox comes first among the long-lived sources. Flickr, S3 and OneDrive need only a mechanism on the roadmap. The UI keeps "Nguồn liên tục" (sources watched forever) apart from "Lần nhập" (one-time jobs). Rounds 1–2 (v0.2.0, v0.3.0) shipped the source model, folder/Drive/Dropbox one-time imports, `x:` content keys and the import pipeline.

Revision 2 (2026-11-10) folds in the plan audit (`reports/plan-audit-dropbox-continuous.md`, 2 Critical, 8 Important, 11 Minor) with the lead's decisions; each is recorded under Decisions. Revision 3 folds in the re-audit (`reports/plan-reaudit-dropbox-continuous.md`, 0 Critical, 6 Important, 15 Minor). Two lead defaults (modified file = new version, remove = cancel with the grant deleted) wait for the owner: see "Unresolved questions".

The long-term design doc on branch `docs/future-continuous-sources` (`docs/architecture/continuous-source-extension.md`, R1–R15, roadmap `docs/requirements/roadmap.md`, decision 0029 "Photos-only continuous source") merges before this plan resumes; phase 07 updates those files instead of adding parallel ones.

## Outcome

Settings › Nguồn › **Nguồn liên tục** lists Photos and every watched Dropbox folder. **Thêm nguồn… › Dropbox…** signs in (existing PKCE flow) and opens the folder browser at `/Camera Uploads` when it exists. Watching the whole Dropbox is allowed after a warning. Each row shows a status dot like a destination:
- Đang theo dõi · kiểm tra lần cuối …
- Đang đọc N file mới
- N file chưa đọc được · thử lại mỗi ngày
- Không kết nối được
- Cần đăng nhập lại, with a button
- Thư mục đã đổi trên Dropbox (detail: renamed, moved or deleted; remove and choose again)
- Cần xác nhận, with **Xác nhận** and **Gỡ**
- Chờ chỗ trống

**Gỡ…** stops watching, like cancelling an import: files not yet uploaded are dropped, and backed-up files stay. The menu bar popover gets a small "Nguồn" section only while a non-Photos continuous source exists.

## Data flow

```
App: DropboxFolderSheet(purpose: watch) ─► get_metadata(root) → root id ─► copy dropbox-account token → import-<id>
     ─► coordinator.addContinuousSource: row {mode: continuous, kind: dropbox, status: watching, config.remoteRootId, cursor: NULL}

cycle step 2 (.changes), ContinuousFeedStage, ≥ 60 s apart per source (manual trigger skips the wait):
  adapter.changes(since: cursor)     Dropbox: root id checked on probe and before any full listing;
     │                               list_folder / continue until has_more = false; 409 reset → full relist (isComplete);
     │                               a `deleted` entry at or above the root → SourceError.rootChanged (nothing committed)
     ▼                               entries compacted to the net state per path_lower, in feed order
  SourceChanges {files[remoteId, relativePath, pathKey, contentHash, …], removals[.item | .tree], isComplete, cursor}
     ▼  read known rows (by remote id, under removed path keys, folded wanted paths and their `stem (n)` siblings; all rows when complete)
  ContinuousChangePlanner.plan (pure) ─► per path, removals first: removed │ changed │ moved │ returned │ reuse │ insert
     ▼  brake: removals > max(50, 20 % of live rows) → offline "largeRemoval", commit nothing (owner confirms or removes)
  tx per ~500 actions, split only between groups (folded dir + stem), compare-and-set per row; the last tx writes cursor + listed_at + watching
  removed/changed primary of a live asset of this source ─► AssetHandover.retire: deleted_at, local_id retired, jobs recomputed,
      other live rows (any open source) holding the asset → pending (an `importing` one-time import goes back to `scanning`),
      so the next ingest revives it with no upload; cancelImport hands over the same way
  failed rows → pending 24 h after they failed (at once after a complete listing or a sign-in)

cycle steps 3–9, ImportStage (unchanged pipeline, reader seam), only while transfers are allowed (network/power rules):
  groups whose newest member was seen ≥ 1 h ago (or in the first listing) ─► inspect(remoteId) → sha256, metadata, content hash
  ─► dedupe (x: key │ resource sha256 │ fingerprint) ─► ImportIngest x:<sha256> ─► AssetFinalizer; row.remote_hash = hash read
ExportWorker (continuous assets only while transfers are allowed) ─► ResourceLocator.remoteId ─► download by id
UploadRunner / SidecarPlanner / views: unchanged
```

## Phases

| # | Phase | Status | Size | Depends | Files owned |
|---|---|---|---|---|---|
| 01 | [Core: continuous source contract and change planner](phase-01-core-continuous-contract.md) | pending | M | — | Core protocols, models, errors, rules; Core tests |
| 02 | [Store: migration and remote item queries](phase-02-store-remote-items.md) | pending | L | 01 | Store schema, repositories; Store tests |
| 03 | [Engine: change feed stage](phase-03-engine-change-feed.md) | pending | L | 01, 02 | feed stage, hand-over, availability, holds, registry, fake source |
| 04 | [Engine: ingest, export, commands, snapshot](phase-04-engine-ingest-export-commands.md) | pending | L | 03 | ImportStage, ExportWorker, transfer gate, recovery, commands, snapshot |
| 05 | [Dropbox continuous adapter](phase-05-dropbox-continuous-adapter.md) | pending | M | 01 | Sources/PhotoVaultDropbox, Dropbox tests |
| 06 | [App: Nguồn liên tục UI, menu bar, scheduler](phase-06-app-continuous-sources-ui.md) | pending | M | 04, 05 | PhotoVault/**, AppSupport text, guard, Keychain sweep |
| 07 | [Docs: spec, decision 0031 or later, extension doc, roadmap](phase-07-docs-provider-guide.md) | pending | S | 06 | docs/**, README.md, site/** |

Phase 05 runs in parallel with 02–04; their file sets do not overlap. Phases 01 → 02 → 03 → 04 are sequential: 01, 03 and 04 all edit `ImportStage*.swift`.

## Acceptance criteria

1. Over several cycles of a fake feed, these give exactly the expected assets:
   - adds, modifications, deletions, renames and case-only renames;
   - a delete and re-add of the same name with a new id, and a folder deleted and recreated, in one feed;
   - moves in and out of the root, a deleted folder, a cursor reset;
   - more than 500 mixed actions in one feed.

   No destination original is overwritten or deleted (`FakeDestination` write log), and no original is uploaded twice. Sidecars may upload again when their `source` block changes.
2. Renames, edits and deletions:
   - A rename or move inside the root uploads nothing.
   - A modified file, read once it has been settled for an hour, becomes a new asset. The old asset keeps its backed-up files and is marked deleted.
   - A file deleted in Dropbox marks its asset deleted and its files stay. If another live row of an open source still holds the same bytes, that row takes the asset over with no upload.
3. A renamed, recreated or deleted root never removes a row. It holds the source with `rootChanged`. A feed that would remove more than max(50, 20 %) rows commits nothing until the owner confirms. The confirm allowance equals the removal count seen at the trip, is used at most once, survives relaunch, sign-in and the confirm itself, and is cleared only by use or by removing the source; the source can never be wedged.
4. The same bytes as a live Photos asset (by SHA-256, or by the fingerprint before it is exported) or as an imported file are counted as already backed up.
5. Crash safety (NFR-01): killing the app after any feed batch, after inspect or after a group commit, then restarting, gives no duplicate item, asset or upload and loses no change.
6. Errors and network rules:
   - A revoked grant shows "Cần đăng nhập lại" and holds only that source. Photos keeps uploading, and signing in again with the same account resumes at the next cycle.
   - No Dropbox download runs while uploads are held by the network or power rules.
7. Removing a source behaves like cancelling an import (FR-115):
   - Assets with unfinished jobs are treated as deleted, and fully backed-up assets stay.
   - The grant is deleted.
   - Adding the folder again reuses every asset with no original uploaded again.
8. Failed files of a continuous source are retried 24 h after they failed, and the row shows their count. A hand-over into a one-time import that is uploading (`importing`) is read and the import still completes; cancelling an import hands its assets over to watched sources that hold them.
9. One-time imports behave exactly as in 0.4.0: their suites are unchanged and green.
10. Builds and checks:
    - `swift test` and the unsigned `xcodebuild` build pass.
    - `UITextCoverageTests` passes.
    - Logs carry no path, name, id, cursor or email.

## Test matrix

| Level | What | Phase |
|---|---|---|
| Unit (Core) | Planner:<br>- New id at a free path; at a path held by a live id (`stem (2).ext`, skipping an existing `stem (2)` row); at a removed row.<br>- Move (same hash) vs change (new hash) for pending, duplicate, imported primary and imported companion rows.<br>- `.tree` removals: exact key, children, not a sibling prefix, exact case. One `.item` case.<br>- A removal of an id that is listed again is a move.<br>- A complete listing removes the unlisted rows.<br>- `returned` with an unchanged hash restores the asset; with a new hash it goes pending.<br>- Per-path order (removals first); Unicode case folding ("ẢNH" vs "ảnh").<br>- Applying the plan twice gives no action. | 01 |
| Store | - Migration on the previous schema keeps rows (new columns NULL).<br>- Remote fields round-trip.<br>- Exact (case-sensitive) path-key prefix and folded-path lookups.<br>- Group-level `readyBefore`.<br>- Compare-and-set updates; `markRemoved` keeps `asset_key`; the hand-over query; the failed → pending reset.<br>- Cursor get/set. | 02 |
| Engine integration (`FakeContinuousSource` + `FakeDestination`) | - Delete and re-add the same name with a new id, and a folder deleted and recreated, in one delta (row removed, new id reuses it, no `(2)`).<br>- Brake confirm, then a sign-in and a relaunch before the next feed: the allowance is still there and the next feed applies once; a feed removing more than the confirmed count trips again; the allowance is gone after use or after removing the source.<br>- Hand-over into an `importing` one-time import: it goes back to `scanning`, reads the row and completes; `cancelImport` hands its asset to a watched source.<br>- First sync; insert, modify, delete, rename and case-only rename over 3+ cycles; move out and back; folder delete; shared-folder unmount and remount (revive, no upload).<br>- Cursor reset; more than 500 mixed actions; an existing `IMG (2).jpg` row.<br>- `rootChanged` (rename and recreate of `/Camera Uploads`, deleted root, `.tree(root)`); large-removal brake, then confirm or remove.<br>- Hand-over: in-source duplicate copy, RAW deleted with the JPEG kept, a second watched folder, removal of a source.<br>- Bytes changed between feed and inspect; a pair split across two polls with the settle delay; a modification inside the settle window.<br>- Failed group retried; poll throttle; transfers held (expensive network, battery).<br>- Dedupe against Photos (hash, fingerprint) and a one-time import.<br>- Offline, busy, revoked grant at the feed and at export; sign in again.<br>- Remove and re-add; export `resourceMissing`, then the file returns (jobs re-armed); one-time import regression. | 03, 04 |
| Crash | - `afterContinuousFeedBatchCommit` mid-listing.<br>- A delete or change re-delivered after a crash before the cursor commit.<br>- A crash after a hand-over batch.<br>- `afterImportInspectBeforeCommit` and `afterImportGroupCommit` on a continuous source. | 03, 04 |
| Adapter (stub transport) | - First listing with paging; root id checked on probe and before a full listing; `deleted` root or ancestor → `rootChanged`.<br>- Continue with add, modify, move, case-only rename, file and folder delete; compaction in feed order; `reset` → complete relist after the root check.<br>- Content hash computed while streaming matches Dropbox's reference vector.<br>- Hidden and unsupported files skipped.<br>- 401 refresh once, revoked, 429/5xx busy, network unavailable.<br>- Download by id; no paths in logs. | 05 |
| AppSupport | - Status presentation per state and reason.<br>- Root nesting guard.<br>- Orphan grant sweep.<br>- Overall header with source work.<br>- UI text coverage. | 06 |
| Manual E2E (owner) | Run on a build with the final migration id, or on a copy of the data folder (see Rollback).<br>- Watch `/Camera Uploads`.<br>- A new phone photo appears within the poll + settle window and is not uploaded twice when it is also in iCloud Photos (HEIC kept as HEIC).<br>- Rename and move in Dropbox upload nothing.<br>- Delete keeps the backup.<br>- Rename the watched folder → "Thư mục đã đổi trên Dropbox", nothing marked deleted.<br>- Revoke the app in Dropbox → "Cần đăng nhập lại" → sign in → resumes. | 06 |

## Rollback

Each phase is its own commit range on the feature branch. Destinations are never touched by a rollback. The persistent change is the additive migration `continuous-sources`: five nullable `import_item` columns, three nullable `source` columns (`cursor`, `blocked_removals`, `removal_allowance`) and three indexes.

Going back to an older build after a continuous source was added is **not supported**:
- 0.4.0 cannot decode `status = 'watching'` or `state = 'removed'`. `RowDecoding.parse` throws `corruptRow`, so every cycle and snapshot fail, Photos backup included.
- Builds that carry feat/27's newer-schema guard (`hasBeenSuperseded` in `Store.open`) refuse a database with a migration id they do not know. 0.4.0 has no such guard and fails with `corruptRow` instead.

The way back is the backup FR-52 takes before migrating, or the owner's reset (delete the local database and resync, decision 0023).

The migration id has no number. It is registered after whatever is last on the base branch at merge and is never renamed once a build has run it. The owner's E2E runs only on a build with the final id, or on a copy of the data folder.

## Merge overlap with feat/27-split-day-by-place

Checked against its plan (`plans/261110-0735-27-split-day-by-place`, worktree `photovault-27-split-day-by-place`). No layout, placement, move or recovery-writer code is touched here; `AssetFinalizer` is only called. Shared files:
- `Sources/PhotoVaultStore/Schema.swift`: both register a migration after `v5-sources`. This plan's id `continuous-sources` needs no rename; order is decided at merge, before any release.
- `Sources/PhotoVaultEngine/EngineEnvironment.swift`: one new `CrashPoint` case. #27 may add cases next to it, an adjacent-line conflict only.
- Docs (`photovault-spec-v1.md`, `system-architecture.md`, `decisions/README.md`): text conflicts. Decision numbers 0028 (split-day), 0029 (Photos-only continuous source, docs branch) and 0030 (Drive import with `drive.readonly`) are taken; phase 07 uses the next free number at resume time (0031 or later).

## Decisions

Plan complete and audited; implementation on hold by owner decision 2026-11-10: Photos is the only continuous source for now. `docs/architecture/continuous-source-extension.md` (branch `docs/future-continuous-sources`) points here as the place to resume.

### Change feed contract in Core
- Chosen: `protocol ContinuousSource: ContentSource { probe(); changes(since cursor: String?) -> SourceChanges; inspect(remoteId:uti:mediaType:control:) }`.
  - `SourceChanges` carries:
    - `files`: each with a stable `remoteId`, the current `relativePath`, a provider `pathKey`, a `contentHash` that changes exactly when the bytes change, size and dates;
    - `removals`: `.item(remoteId)` or `.tree(pathKey)`;
    - `isComplete`: this is the whole state;
    - an opaque `cursor`.
  - Adapters return the net state per `pathKey`, compacted in feed order. They follow their own pagination and answer a cursor reset with a complete listing. `InspectedFile` gains the provider `contentHash` of the bytes actually read, and `ResourceLocator` gains `remoteId`.
- Alternatives: `ContinuousSource: FolderImportSource`, reusing `listFiles` and the path-based `inspect`; a provider-specific engine stage; the engine handling `.cursorExpired` itself
- Why: the engine stays provider-neutral, and every provider fits:
  - Dropbox reports only paths for deletes, so it uses `.tree`;
  - the OneDrive delta reports ids, so it uses `.item`;
  - S3 and Flickr have no usable delete feed, so they return `isComplete`.

  Net-state compaction honours Dropbox's in-order processing rule (audit M5). `.item` has no producer until OneDrive; it is kept because it is cheap, with one test (M11).
- Review later: no

### Identity: `x:<sha256>` keys, the database owns remote ids and paths
- Chosen: continuous assets use the import key `x:<sha256 of the primary>`. This supersedes the `s:` plan of decision 0024.
  - Each `import_item` row is a path slot. Its `rel_path` is fixed when the file is first seen.
  - New columns: `remote_id`, `remote_hash`, `remote_path` (Dropbox `path_lower`), `path_fold` (Swift Unicode case fold of `rel_path`, used for slot lookups) and `seen_at`.
  - Path-key prefixes are compared exactly with `substr`, never `LIKE`, which ignores ASCII case. `local_id` stays `<sourceId>/<rel_path>`.
- Alternatives: `s:<sourceId>/<remoteId>` keys with `@<rev>` versions; keeping id↔path in `RemoteIdIndex`; SQLite `lower()` for folding
- Why: `x:` keys give dedupe, recovery and the export hash check for free. The id↔path map must commit with the cursor, or a crash loses a deletion. SQLite folds ASCII only, so "ẢNH.jpg" and "ảnh.jpg" would not collide (audit M1).
- Review later: no

### Root guard and mass-removal brake (lead decision, audit C1)
- Chosen: all three guards.
  1. Root id check:
     - `SourceConfig.remoteRootId` stores the Dropbox id of the root folder at add time (`get_metadata`; the whole Dropbox has none).
     - The adapter checks it on `probe()` and before any full listing. A different id or a missing root throws the new `SourceError.rootChanged`.
     - The source holds `offline` with reason `rootChanged`, and nothing is committed.
  2. Deleted root: a `deleted` entry at or above the root is never turned into removals. It throws `rootChanged` too.
  3. Engine brake: a feed whose `removed` actions exceed max(50 rows, 20 % of the source's live rows) commits nothing.
     - The source holds `offline` with reason `largeRemoval` ("cần xác nhận").
     - The owner can **Xác nhận**, and the next feed applies once, or **Gỡ** the source.
- Alternatives: the root guard alone; the brake alone; no guard ("backups are kept anyway")
  - A trip holds the source for 10 minutes (`signInBackoff`) so it does not replan the whole delta on every poll, and stores the removal count it saw in `source.blocked_removals`.
  - **Xác nhận** acts only while the reason is `largeRemoval`. It copies that count into `source.removal_allowance`, sets `watching` and clears only the cooldown (`ImportHolds.clearCooldown`).
  - The cap is explicit: the allowance equals the removal count seen at the trip (no margin) and is used at most once. A feed whose removals are within it applies, and its final transaction clears the allowance; a feed with more removals trips again and records the new count, leaving the old allowance unused.
  - The allowance is cleared only by that use or by removing the source. Sign-in (`ImportHolds.clear`), a relaunch and the confirm itself never clear it, because it lives in the database, not in the holds (lead decision, docs-branch sync).
  - A held source sends no notification; the Settings row and the popover "Nguồn" section show the state (accepted, re-audit M-2). Following a renamed root by its id (`get_metadata(rootId)` gives the new path) would avoid a remove and re-add; Review later.
- Why: renaming `/Camera Uploads` and letting the phone recreate it, or deleting the root, would otherwise retire every asset. Pending uploads would be cancelled and later destinations would skip them all. The brake catches unforeseen mass *removals* only; a bug in the hash signal produces `changed` actions, which retire assets but cost only a re-download, because the same bytes revive under the same `x:` key.
- Review later: yes

### A modified file is a new version; nothing is overwritten (lead default, audit I6; owner to confirm)
- Chosen: a known `remote_id` with a new `contentHash` resets its row to `pending` with `seen_at = now`, so the one-hour settle window applies. Only the version present after the window is read. Its group key is `FolderItemGrouper.groupKey(rel_path)` plus one token per feed (`"#v"` + 8 hex of the SHA-256 of the new cursor), so files of one pair changed together stay one group and keys never grow.
  - It becomes a new `x:` asset.
  - When the row was the primary of a live asset of this source, that asset is retired (`deleted_at`, `local_id` → `<old>#<16 hex of its key>`), and other holders take it over (see the next decision).
  - A changed companion becomes its own asset, and the old pair stays live.
  - The root picker opens on a folder (`/Camera Uploads` when it exists). Watching the whole Dropbox needs a confirmation that warns that every edit adds a copy.
- Alternatives:
  - edit semantics, uploading `_edited` files replaced in place;
  - a per-poll threshold that asks the owner;
  - keeping the old asset live.
- Why: originals are never overwritten ("Không bao giờ ghi đè file gốc"), and a second edit would overwrite the first. The settle window absorbs editors that save several times. Archive growth from tools that rewrite metadata in place (Lightroom, digiKam) is the accepted cost; the warning tells the owner before they pick a working folder.
- Review later: yes

### Retirement hands an asset over instead of dropping it (lead decision, audit C2)
- Chosen: `AssetHandover.retire` acts only when the asset is live, belongs to this source and its `local_id` is this row's.
  1. It marks the asset deleted and retires its `local_id`.
  2. It moves every other `imported` or `duplicate` row with `asset_key = K` in any open source (continuous `watching`/`offline`, or an open one-time import) back to `pending`. Those rows get a suffixed group key and `seen_at = NULL`. Rows that the current plan itself removes or changes are excluded.
  3. In the same transaction, every one-time import that receives a row and is `importing` goes back to `scanning`, or it would wait forever for a pending row it never reads (re-audit I-1).
  4. The next ingest revives K under such a row, with no upload because done jobs stay done, or takes it over when its owner was removed.
  - `cancelImport` hands over too: each asset it deletes goes through the same step 2, excluding the import's own rows (re-audit I-3).
  - A handed-over companion, such as the JPEG left when its RAW is deleted, becomes its own `x:` asset. It may be uploaded once more under its own name; it is never lost.
- Alternatives: retire regardless (the audit's failure); never retire while any row in any source, closed ones included, points to K; hook `ChangeTracker` deletions too
- Why: a photo still present in a watched folder must stay backed up for later destinations. Closed one-time imports are not handed over, because nothing ingests their rows; running the import again revives the asset. A Photos deletion does not re-queue continuous `duplicate` rows: that would re-upload the Photos copy under a new path, and Photos code stays untouched. Both are documented limits.
- Review later: yes

### Deletions, renames, moves and case
- Chosen:
  - Deletions:
    - A deleted path removes every live row whose `remote_path` equals the key or lies under `key/` (exact case), unless the id is listed again in the same feed, which makes it a move.
    - A listed file whose `pathKey` is the `remote_path` of a live row with another id, not listed elsewhere, removes that row; the new id then reuses it (re-audit I-2). This covers safe-save editors, delete + re-add and providers that never report the delete.
    - A removed row keeps `asset_key` and `is_primary`; a primary is retired with hand-over.
  - Renames and moves:
    - A rename, case-only rename or move inside the root only updates `remote_path`.
    - A move out of the root is a deletion.
    - A move back, or a shared folder remounted, is `returned`. Every row of the asset whose hash is unchanged (primary and companions) is restored in the feed transaction: no download, no settle wait, and `resourceMissing` skips are re-armed (audit M2). If another source took the asset over meanwhile, the rows become `duplicate` of it. With a new hash a row goes to `pending`.
  - Name collisions:
    - A new id at a path held by a live id gets the first `stem (n)` free for every member of its base group (folded dir + stem), so a new RAW+JPEG pair gets `IMG (2).CR2` and `IMG (2).JPG`.
    - A new id at a removed row's path reuses that row.
- Alternatives: delete by path only (re-upload on every move); re-download returned files; refuse path reuse
- Why: the same semantics as Photos deletions, with ids making moves free. The prefix rule works whether or not Dropbox lists a deleted folder's children `[UNVERIFIED]`.
- Review later: no

### Feed ordering, batching and crash safety (lead decision, audit I1)
- Chosen:
  - Order and batching: actions are ordered by `rel_path`, with removals first within a path (removed → changed → moved → returned → reuse → insert). Batches of about 500 split only between base groups (folded dir + stem), so a path's actions and a pair's rows always commit together.
  - Compare-and-set: every update checks `(source_id, rel_path, expected remote_id)` and skips a row that no longer matches. An insert re-checks that its folded path is free inside the transaction and takes the next `(n)` if not, so the primary key can never be hit.
  - Commit: the last transaction writes the cursor (`source.cursor`), `listed_at` (last check) and `watching`. The removals of a complete listing are computed over the whole listing first.
- Alternatives: global ordering by action kind; one transaction per feed; cursor in `key_value`
- Why: a `reuse(p)` and its `removed(p)` can never land in different batches, half a pair is never committed alone, and a stale plan cannot overwrite a row. The pattern matches the Photos change token, committed with its change. A first listing of 100 k files should not be one write.
- Review later: no

### Where the feed runs and how often
- Chosen: `ContinuousFeedStage` at cycle step 2 (`.changes`), at most once per 60 s per source; a manual trigger skips the wait.
  - The 15-minute disk-recheck timer's condition becomes `diskLow || needsSourcePoll` (a continuous source is open).
  - The 5-minute recheck covers sources with *ready* pending groups or `offline/unavailable`, not rows still waiting out the settle window (audit M6), and is skipped while uploads are held (re-audit M-11).
  - No longpoll.
  - The cycle, Dropbox included, still needs Photos access and the baseline (audit M9, documented).
- Alternatives: longpoll in an app task; polling in every round; a 5-minute timer
- Why: a `continue` call with no change is cheap. A backup does not need second-level latency, and longpoll needs its own task and backoff.
- Review later: yes

### Files wait one hour, per group, before they are read (lead decision, audit I3)
- Chosen: a group is ready when its newest member's `seen_at` is NULL (first listing, hand-over) or at least an hour old. Readiness is decided per group (`HAVING MAX(COALESCE(seen_at, 0)) ≤ ?`), and every pending member of a ready group is offered together. Changes and additions after the first listing set `seen_at = now`.
- Alternatives: per-file readiness; no delay; a looser fingerprint for camera-upload names
- Why:
  - A phone uploading to both iCloud Photos and Dropbox delivers the same photo to both. Waiting lets Photos export it first, so the Dropbox copy matches by SHA-256 (Camera Uploads renames files, so the fingerprint cannot match).
  - Per-group readiness keeps RAW+JPEG and Live pairs together across polls.
  - A looser fingerprint would drop burst frames.
  - The wait only helps when Dropbox keeps the original bytes `[UNVERIFIED]`.
- Review later: yes

### Read hash = stored hash (lead decision, audit I2)
- Chosen: `inspect` returns the provider content hash of the bytes it read. For Dropbox it is computed while streaming: SHA-256 of the concatenated SHA-256s of 4 MiB blocks. The group commit stores it as each member's `remote_hash`.
- Alternatives: reading by `rev:`; trusting the feed's hash
- Why: a file that changes between the feed and the read would otherwise retire the asset just built from it and download it again.
- Review later: no

### Downloads follow the upload network and power rules (lead decision, audit I7)
- Chosen: one `TransferGate.allowsNow` (network, `pauseOnExpensiveNetwork`, `allUploadsOnlyOnACPower`) shared with the coordinator's upload check. While it says no:
  - continuous ingest reads nothing;
  - continuous assets leave the export candidates;
  - the feed listing still runs, because it is a few small requests.

  One-time imports keep 0.4.0 behaviour.
- Alternatives: gate the feed too; gate every cloud source, imports included
- Why: a background whole-Dropbox source must not pull gigabytes over a hotspot or on battery when uploads would not run anyway. Imports are started by the owner, and changing them is out of scope.
- Review later: yes

### Failed files of a continuous source are retried daily (lead decision, audit I4)
- Chosen: when a continuous row is marked `failed`, its `seen_at` records the failure time. The feed requeues `failed` rows (`pending`, `seen_at = NULL`, group failures forgotten) once that time is 24 h old, and all of them at once after a complete listing or a sign-in. The row shows "N file chưa đọc được · thử lại mỗi ngày". No **Thử lại** button.
- Alternatives: a **Thử lại** button; an in-memory retry clock; never retry (the import rule)
- Why: a continuous source has no "import again", and an unchanged hash produces no feed action. A persisted failure time keeps the cadence daily: with an in-memory clock, a group given up after FR-124's 10 tries over 24 h would be due again at once and retried about hourly (re-audit M-3).
- Review later: no

### First sync of an existing folder: like an import
- Chosen: rows of the first listing (`seen_at = NULL`) are read at once with the import pacing, `inserted_at` set to the ingest time, `incremental` jobs, and no backfill bucket. The transfer gate applies. Each file is downloaded twice (hash, then export), even if a 0.3.0 import already backed it up.
- Alternatives: backfill origin; dedupe before download with `content_hash`
- Why: consistent with decision 0024. Pre-download dedupe would only help with hashes that no earlier source stored.
- Review later: yes

### Whole account or one folder; one grant per source
- Chosen: one root per source, chosen in the existing browser.
  - The browser opens at `/Camera Uploads` when it exists. The whole Dropbox is allowed after a warning.
  - Two open continuous sources of the same account may not overlap (equal or nested roots, Unicode case-insensitive).
  - Each source keeps its own `import-<sourceId>` token copy, re-registered at launch and deleted by factory reset.
  - At launch, the app deletes `import-*` items whose row is missing or is a removed continuous source (audit M3).
  - Sign-in again reuses the import flow (same account), resuming to `watching`.
- Alternatives: whole account only; one shared token
- Why: overlapping roots would download everything twice. Per-source grants already survive sign-out (decision 0026). A crash between the token copy and the row write would otherwise leave a stray grant.
- Review later: no

### Status model
- Chosen: `SourceStatus.watching` (open). A continuous source is:
  - `watching`;
  - `offline`, with reason `unavailable`, `signInRequired`, `rootChanged` or `largeRemoval`; `diskFull` shows while files wait for room;
  - `cancelled`, once removed.

  "Reading N new files" and "N failed" come from row counts. It never completes and writes no activity row. `holdSource` covers `watching`. `cancelImport` refuses continuous rows; only `removeContinuousSource` closes them (audit M4).
- Alternatives: reuse `scanning`/`importing`; a `removed` status
- Why: every open-import rule (holds, offline exclusion, last-successful-sync) applies unchanged, and the row reads like a destination.
- Review later: no

### Removing a continuous source = cancelling an import (lead default, audit I8; owner to confirm)
- Chosen: one lane command. The steps follow `cancelImport` (FR-115), asset by asset (audit M10):
  1. Pending rows become `cancelled`.
  2. Each live asset of the source with a pending, uploading or deferred job is retired through `AssetHandover`. Its unfinished jobs are cancelled and other holders take it over.
  3. Fully backed-up assets stay live. Rows of other open sources that hold them go back to `pending` and take them over; the removed source's own rows are excluded.
  4. The status becomes `cancelled`, the cursor is cleared, the adapter is unregistered and the holds are cleared. The app deletes the grant.

  A destination added later skips the kept assets nobody took over (`resourceMissing`). Adding the folder again takes them over or revives them, with no original uploaded again.
- Alternatives: mark every asset deleted (revision 1); keep the grant so later destinations still read them (imports' choice in 0026)
- Why: lead default: same meaning as cancelling an import. The grant goes because the owner removed the account's access from PhotoVault's view. The visible `resourceMissing` skips are the price. The docs branch (R12) currently says the grant is kept; phase 07 aligns it with whatever the owner confirms.
- Review later: yes

### UI: "Nguồn liên tục" and "Lần nhập" stay apart
- Chosen: Settings › Nguồn › Nguồn liên tục has:
  - the Photos row;
  - one Dropbox row per source: name, account, dot and status, last check, pending and failed counts, and **Đăng nhập lại**, **Xác nhận** or **Gỡ…** as needed;
  - **Thêm nguồn… › Dropbox…**.

  The browser gets a "watch" purpose. The popover shows "Nguồn" above "Đích" only while a non-Photos continuous source exists. The overall header reads "Đang đọc ảnh từ nguồn" when that is the only work. No notification.
- Alternatives: a permanent popover section; listing continuous sources under imports
- Why: owner decision (two vocabularies); a Photos-only menu stays unchanged.
- Review later: yes

### Migration id without a number (lead decision, audit I5)
- Chosen: the id is `continuous-sources`, registered after the last migration on the base at merge and never renamed once any build has run it. The Rollback section states that downgrade is unsupported.
- Alternatives: `v7-continuous-sources`, renamed to `v6` at merge
- Why: with #27's newer-schema guard, a renamed migration makes any database that ran the branch refuse to open. Without the guard, the renamed migration re-runs `ADD COLUMN` and fails.
- Review later: no

### Provider mechanism: the existing extension doc and roadmap, no code
- Chosen: the mechanism lives in `docs/architecture/continuous-source-extension.md`. Its section "Hướng dẫn thêm nhà cung cấp" is the provider guide; the doc also holds the contract, safety rules R1–R15 and the provider table for Dropbox, OneDrive, S3 and Flickr, marked `[UNVERIFIED]`. The roadmap list is `docs/requirements/roadmap.md`, which the owner asked for and which stays. Both come from branch `docs/future-continuous-sources`, which merges before this plan resumes. Phase 07 edits both to match this plan (R8 retry without a button, R10 feed listing not gated, R12 grant per the owner's answer, the I-2 path rule, the brake allowance) and creates no other guide. The decision record takes the next free number at resume time (0031 or later) and supersedes 0029.
- Alternatives: a separate provider guide file; roadmap entries only in spec §15; a plugin protocol with registration code now
- Why: one living doc per subject (DRY); the docs branch already holds the provider guide and the roadmap the owner asked for. 0028–0030 are taken.
- Review later: no

### Accepted limits (audit M7, M8, M9)
- Chosen:
  - An export-side hold (a download fails while the API answers) is cleared by the next successful feed. The source may flip between `offline` and `watching` at most once per poll, with held exports recording no error.
  - Revived assets may upload their sidecars again when the `source` block changes; originals are not uploaded again.
  - Dropbox stops with the cycle when Photos access is lost.
- Alternatives: a download probe to clear the hold; a sidecar `source` block that ignores the source id; a cycle without Photos
- Why: each fix costs more than the symptom (a status flicker, a few KB of sidecars, a rule that is already documented). All three are listed in FR-130 and the README.
- Note: `plan-phases.cjs --check` warns `status-unknown` for `status: on-hold`; the status is intended while implementation is on hold.
- Review later: no

### Smaller choices
- Chosen:
  - No activity rows for feed changes; counts go to the log only.
  - One Dropbox listing mapper shared by the import and the continuous adapter.
  - Feed constants (60 s, 1 h, 24 h, 50 / 20 %) are static on the stages, not in `EngineEnvironment.Tuning`.
  - A revive of a continuous asset re-arms its `resourceMissing` skips, so a file that comes back after an export failed is uploaded.
- Alternatives: a summary row per poll; separate mappers; tuning fields; manual retry of skipped jobs
- Why: activity stays readable, one notion of a file's path, the #27 overlap in `EngineEnvironment.swift` is limited to one line, and a returned file is not left skipped.
- Review later: no

## Risks (top)

- **High:** a feed bug marks many assets deleted.
  - Mitigations: the root id guard, deleted-root refusal and the brake (C1); a pure planner with exhaustive tests; compare-and-set; hand-over (C2); backups are never touched.
- **High:** ImportStage regressions for one-time imports, since the code is shared.
  - Mitigations: a mode filter (in phase 03, before the feed stage runs), the reader seam, group-level readiness applied only when `readyBefore` is passed, and the unchanged import suites as the gate.
- **Medium:** Camera Uploads with iCloud Photos uploads the same photo twice when Dropbox converts HEIC to JPG. Accepted; the owner's E2E measures it.
- **Medium:** the archive grows with every edit in a watched working folder (I6). Mitigated by the settle window and the whole-account warning; Review later.
- **Medium:** merge overlap with #27 (migration order, `CrashPoint`, docs); see "Merge overlap".
- **Low:** in deltas, Dropbox `path_display` casing of directories is unreliable. A RAW and a JPEG whose directory spelling differs between polls are not paired (the grouper keys on the directory as written), and album titles may differ in case. Accepted; the settle window makes most pairs arrive in one poll.

## Unresolved questions

Owner to confirm when resuming (the plan uses the lead's default until then):
- **Modified file (audit I6).** Default: a changed file is a new version after the 1-hour settle window; the old asset is marked deleted, its backups stay; the whole-Dropbox choice warns about archive growth. Other options: (b) the same plus a per-poll threshold that holds the source and asks (for example more than 50 changed files); (c) keep the old asset live.
- **Removing a source (audit I8).** Default: like cancelling an import (FR-115): assets with unfinished jobs are treated as deleted, fully backed-up assets stay live, and the `import-<id>` grant is deleted, so a destination added later skips what no other source holds. Other option: keep the grant (as one-time imports do) so later destinations still receive those files.

Open facts for the owner's E2E:
- Does a deleted Dropbox folder produce child `deleted` entries? Does a renamed root give `reset`, `not_found` or a `deleted` root entry? The design handles all of them `[UNVERIFIED]`; the owner's E2E will show the real shape.
- Does Dropbox Camera Uploads keep the HEIC bytes identical to the Photos original? Owner E2E.
- Does a Dropbox safe-save (editing a file in place) keep the file id or create a new one? Both are handled (I-2); the E2E should edit one file in place.
- Is a 15-minute poll fast enough, or is longpoll wanted later?
- Who aligns R8, R10 and R12 on `docs/future-continuous-sources` before it merges? Default: phase 07 does it at resume time.
