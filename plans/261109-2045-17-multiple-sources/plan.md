---
title: "Back up from several sources: source model and one-time folder import"
description: "Source abstraction plus a one-time import of a folder on this Mac, organised exactly like Photos assets; cloud sources deferred"
status: pending
priority: P2
size: L
human_effort: 7-14h
issue: 17
branch: feat/17-multiple-sources
tags: [sources, import, engine, schema, ui]
created: 2026-11-09
sources:
  - "tracker: github:Chubby-Chocobo/photovault#17"
  - "spec: file:docs/requirements/photovault-spec-v1.md"
authoritative: "tracker: github:Chubby-Chocobo/photovault#17"
---

# Plan: several sources, one layout (issue #17)

Owner (2026-11-09): Photos stays the main, long-lived source with a steady flow of new photos. Other long-lived sources will follow (Dropbox, Flickr, another Google account). One-time jobs import everything from a chosen folder (on this Mac, on Google Drive, on another cloud). Whatever the source, photos land in the PhotoVault destination organised the same way.

This round ships the source model and the **one-time import of a folder on this Mac**. Cloud sources are written up as deferred phases, each with what the owner must register first.

## Outcome (this round)

Settings › **Nguồn / Sources**: Photos (the main source) and a list of import jobs. **Nhập từ thư mục… / Import from folder…** opens an `NSOpenPanel` and takes a read-only security-scoped bookmark. The job lists the folder recursively, groups RAW+JPEG and Live pairs, reads EXIF/QuickTime metadata, hashes each file and drops duplicates. It then feeds the normal pipeline: placement, export to staging, fan-out uploads, sidecars, views. Each job row shows progress and a cancel button. A summary row appears in Recent activity when the job finishes. A file imported this way gets the same path a Photos asset with the same metadata would get: `Camera Uploads/YYYY-MM-DD[ place]/YYYY-MM-DD HH.mm.ss_<name>`, `Screenshots/<day>/`, `Saved/<day>/`, `<branch>/Unknown date/`, plus By device and By place.

## Data flow

```
NSOpenPanel ─► bookmark(read-only) ─► SyncCoordinator.startFolderImport (lane) ─► source row [scanning] + SourceRegistry.add(LocalFolderSource)
cycle step 3 (ImportStage, per round, bounded):
  listFiles ─► import_item rows (INSERT OR IGNORE)            tx per 500
  per group (same dir + stem): inspect = sha256 + FileMetadata (outside tx)
  tx: dedupe (x:<sha256> key │ resource.sha256 │ fingerprint vs live assets)
      ─► ingest asset key x:<sha256>, source_id, inserted_at=now, final category
      ─► AssetFinalizer (placement, day_stat, jobs as for any asset) ─► items imported/duplicate
ExportWorker ─► SourceRegistry.content(for: asset.source_id) ─► LocalFolderSource.exportResource ─► staging (md5+sha256)
UploadRunner / SidecarPlanner / views: unchanged (sidecar gains a `source` block for non-Photos assets only)
ImportStage: no pending item and no pending/uploading job ─► [completed] + one activity row
```

## Phases

| # | Phase | Status | Size | Depends | Round |
|---|---|---|---|---|---|
| 01 | [Core source model and identity](phase-01-core-source-model.md) | completed | M | — | this |
| 02 | [Store: sources schema](phase-02-store-sources-schema.md) | completed | M | 01 | this |
| 03 | [Engine: source routing, Photos-only passes](phase-03-engine-source-routing.md) | completed | L | 01, 02 | this |
| 04 | [Folder adapter and file metadata](phase-04-folder-adapter-and-metadata.md) | completed | M | 01 | this (parallel with 02–03) |
| 05 | [Engine: folder import job](phase-05-engine-folder-import.md) | completed | L | 02, 03, 04 | this |
| 06 | [App: Sources tab and import UI](phase-06-app-sources-ui.md) | pending | M | 05 | this |
| 07 | [Docs, spec amendment, decision 0024](phase-07-docs-and-decision.md) | pending | S | 05, 06 | this |
| 08 | [Continuous non-Photos source runtime](phase-08-continuous-source-runtime.md) | pending | L | 05 | **deferred** |
| 09 | [Google Drive folder import (one-time)](phase-09-google-drive-folder-import.md) | pending | L | 05 | **deferred**, owner setup |
| 10 | [Another Google account](phase-10-another-google-account.md) | pending | L | 08, 09 | **deferred**, owner choice + setup |
| 11 | [Dropbox (continuous)](phase-11-dropbox-source.md) | pending | L | 08 | **deferred**, owner registers app |
| 12 | [Flickr (continuous)](phase-12-flickr-source.md) | pending | L | 08 | **deferred**, owner API key |

`human_effort` 7-14h covers phases 01–07. The deferred phases add about 11-22h once the owner has done their setup.

## Acceptance criteria (this round)

1. An imported file ends up at the same destination path and file name as a Photos asset with the same date, category, place and original name. The parity test in `FolderImportTests` checks this.
2. Duplicates are never uploaded twice. Covered cases: the same bytes twice in one folder, a re-run import, a file already exported from Photos (SHA-256), and a file still waiting in the Photos backfill (fingerprint: date to the second + original stem + pixel size). The job summary counts them as "already backed up".
3. Photos keeps working as before. Keys, sidecars (byte-identical) and Drive appProperties of Photos assets do not change. Reconciliation and cloud-id backfill leave imported assets alone. An offline import folder does not stop Photos exports.
4. Crash safety (NFR-01): killing the app at any point and restarting resumes the job with no duplicate asset or upload.
5. Cancel stops ingesting and cancels jobs that have not uploaded yet. Uploaded files stay. Settings shows progress (found / processed / new / duplicates / skipped / failed), and Recent activity gets exactly one summary row.
6. `swift test` and the unsigned `xcodebuild` build pass. The spec, sidecar schema, architecture doc, README and decision 0024 describe sources.

## Test matrix

| Level | What |
|---|---|
| Unit (Core) | `x:` keys; grouper (RAW+JPEG, Live by content id, singles, sidecar files ignored); date policy; `SourceError` classification; sidecar `source` block present only for non-Photos assets, Photos sidecar golden bytes unchanged |
| Store | v4→v5 migration keeps every row with `source_id = 'photos'`; repositories; `resource.sha256` index used |
| Adapter | listing skips hidden files, packages and `.photoslibrary`; export hashes match `FileHashing`; cancel through `ExportControl`; an unmounted root raises `SourceError.unavailable`; `fileMetadata` on corpus fixtures |
| Engine integration | end-to-end import to `FakeDestination` + a local folder; dedupe cases; reconciliation/backfill isolation; offline source; cancel; completion row once; crash points mid-group and after commit |
| Manual E2E | import a real camera folder (ARW+JPG, iPhone HEIC+MOV, PNG screenshots, WhatsApp JPEGs) to a local destination and to Drive, then compare with the same photos from Photos |

## Rollback

Every phase is its own commit range on the feature branch, so reverting it is safe. The only persistent change is migration `v5-sources`, which is additive: a column with a default, two new tables and one index. Undoing it means restoring the `DatabaseBackup` copy taken before the update. The other way is the owner's existing reset: delete the local database and resync (decision 0023). Destinations are never touched by a rollback.

## Decisions

### Content-addressed keys for one-time imports
- Chosen: an imported asset's key is `x:<sha256 of its primary file>`. Its origin is stored in `asset.source_id` and `import_item`. Continuous non-Photos sources (deferred) will use `s:<sourceId>/<itemId>`, because their files can change.
- Alternatives: `s:<sourceId>/<relative path>` for imports too; a random id per item
- Why: the same bytes get the same key in every job, so re-running an import, overlapping folders or a later Drive import of the same files dedupe for free. After a database loss, a re-run import produces the keys already written in `pvAssetId` and the sidecars, so recovery (8.15) can match them (spec goal 5).
- Review later: yes

### Dedupe = exact SHA-256 or fingerprint against any live asset
- Chosen: an import item is a duplicate when (a) its `x:` key exists, (b) a live asset has a resource with the same `sha256` (Photos assets already exported), or (c) a live asset has the same capture second, original stem (case-insensitive) and pixel size or duration. The fingerprint reuses `NameFingerprint.dateText`. The duplicate is counted, not ingested.
- Alternatives: hash only (misses Photos assets still in the backfill, and re-encoded copies); waiting until the Photos asset is exported (could hold a job for weeks); exporting Photos candidates just to hash them (iCloud downloads, rate limits)
- Why: Photos is the main source and its backfill can take weeks, so most overlaps are with Photos assets that are not exported yet. A false fingerprint match needs the same second, the same file stem and the same size, and in that case the photo is still backed up from Photos. Two gaps stay. A Photos asset that some destination's scope excludes (newOnly, hidden) blocks its folder copy too. A photo added to Photos *after* it was imported is uploaded again (the reverse case is not handled).
- Review later: yes

### Photos stays primary and owns the cycle checks
- Chosen: the cycle still needs Photos access and a baseline before anything runs, imports included. Imports reuse the asset/resource/job tables and the whole pipeline. The new engine code is the import stage and a content router used by export and recovery. Scanner, ChangeTracker, Reconciler, CloudIdBackfill and EditGate stay Photos-only.
- Alternatives: generalise `PhotosSource` into a multi-source protocol used by every pass; a separate pipeline for imports
- Why: smallest change that gives an identical layout (same placement, names, day folders, views and sidecars) without touching Photos semantics.
- Review later: no

### Imports are new arrivals (`inserted_at = ingest time`), origin `incremental`
- Chosen: an imported asset behaves like a photo just added to Photos. It is in the window of `newOnly`/`since` destinations, its jobs are `incremental`, there is no backfill bucket or AC-power gate, and the disk guard applies. Within a priority, candidates are ordered newest capture date first, so today's iPhone photos still go before old imported ones.
- Alternatives: a new `import` origin with its own priority and limits; rate-limiting imports like backfill
- Why: the owner starts an import deliberately and expects it to run. The bucket and power gates exist to protect against Photos downloading originals, which a local folder does not do. No new origin means no change to the job state machine. Revisit if large imports crowd out new Photos uploads or drain the battery.
- Review later: yes

### Read the file twice (hash at ingest, copy at export)
- Chosen: ingest reads each primary once for SHA-256 and the metadata. Export later copies it to staging through the normal `ExportWorker` path.
- Alternatives: adopting the hashed copy as staging during ingest (as `ClassifyWorker` does); APFS `clonefile`
- Why: dedupe must happen before an asset exists. Keeping export unchanged keeps the disk guard, staging generations and crash recovery identical. Local reads cost little next to uploads. A slow NAS source pays the double read.
- Review later: yes

### Date, place, camera and category for files
- Chosen: date comes from EXIF `DateTimeOriginal` (+`OffsetTimeOriginal`, else archive timezone), then QuickTime creation date, then the earlier of the file's creation and modification dates (recorded as `dateSource`). Location comes from EXIF GPS / QuickTime ISO 6709. Camera and lens come from TIFF/EXIF. The category comes from `CategoryClassifier` with the metadata already read, so it is never provisional. Screenshot = EXIF `UserComment` "Screenshot", which iOS and macOS write. A folder name inside the import that matches a chat-app name counts as that album (rule 2). Favorite, hidden, burst and adjustments are all off.
- Alternatives: `Unknown date` when there is no EXIF; filename heuristics for screenshots
- Why: Photos uses the same order for files without EXIF, and the owner asked for the file-date fallback. Filename patterns depend on the locale. Screen recordings have no marker and go to `Camera Uploads`.
- Review later: yes

### Pair RAW+JPEG by name, Live Photos only by content identifier
- Chosen: in one directory, files with the same stem become one asset. A RAW plus an image gives `.photo` + `.alternatePhoto` (primary RAW). An image plus a video gives `.photo` + `.pairedVideo` + `photoLive`, but only when Apple's content identifier matches in both files. Anything else stays a separate asset. `.AAE`, `.XMP`, `.THM` and `.json` are ignored.
- Alternatives: no pairing; pairing any image+video with the same stem
- Why: matches how Photos stores these pairs, so the names and folders come out the same. A wrong Live pairing would hide a real video inside a photo asset.
- Review later: no

### Cancel = stop ingesting and treat unfinished assets as deleted
- Chosen: the remaining items become `cancelled`. Ingested assets of the job with any job not `done` get `deleted_at`, the same rule as a photo deleted from Photos: pending/deferred jobs are cancelled and uploaded files stay. Running the import again revives them, because the keys are the same.
- Alternatives: stop ingesting only and let queued uploads finish; delete uploaded files
- Why: "Huỷ" should stop the work. The app never deletes backup data. The deletion path already exists and is tested.
- Review later: no

### Sidecar `source` block for non-Photos assets only
- Chosen: add `"source": {kind, name, path, dateSource}` to JSON sidecars of imported assets. `localIdentifier` carries the import locator. `schemaVersion` stays 1 (the field is optional). Photos sidecars are byte-identical to today.
- Alternatives: a `source` field on every sidecar
- Why: a field on Photos sidecars would change every hash and re-upload every sidecar (FR-93).
- Review later: no

### Folder name only in Settings, never in activity or logs
- Chosen: the activity summary row says "Đã nhập xong 1 thư mục: …" with counts only. The folder name and path appear in Settings › Nguồn, as destination names do.
- Alternatives: the folder name in the activity row
- Why: code standards: activity and logs never carry file names or paths.
- Review later: no

### Keep the bookmark after completion
- Chosen: the read-only bookmark stays on the source row so the app can export again (staging released early, owner-confirmed reupload).
- Alternatives: drop it at completion
- Why: no new action is needed to re-export, and read-only access to a folder the owner picked is a small exposure. A "remove from list" action is deferred.
- Review later: yes

### Spec non-goals amended by the owner
- Chosen: issue #17 is authoritative over spec §2, which lists Dropbox and several Google accounts as non-goals. Decision 0024 records the amendment. Spec §2 and §15 are updated in phase 07.
- Alternatives: none. The owner's request is explicit.
- Why: `authoritative` = tracker #17.
- Review later: no

### Another Google account cannot be a continuous Google Photos source
- Chosen: phase 10 offers the owner three options: that account's Drive (continuous), a Google Takeout archive (one-time folder import with Takeout JSON dates), or the Photos Picker (one-time, items chosen by hand).
- Alternatives: the Google Photos Library API
- Why: since 2025-03-31 the Library API reads only app-created media, and its readonly scope is gone ([Google Photos API updates](https://developers.google.com/photos/support/updates)).
- Review later: yes

## Risks (top)

- **High:** a Photos-only pass touching imported assets, for example `Reconciler.markGone` marking them deleted. Mitigation: phase 03 adds a filter on `source_id` plus regression tests, before any import code lands.
- **Medium:** metadata parity, where an imported file's date or offset differs from the date Photos shows for the same photo. That breaks the fingerprint and the day folder. Mitigation: a parity test on corpus files. Photos' own date stays authoritative for Photos assets.
- **Medium:** the import folder goes away (external disk unplugged) after ingest but before the uploads finish. The source is then held `offline` and resumes on its own. A file deleted for good becomes a `resourceMissing` skip. The UI says to keep the folder until the job completes.

## Unresolved questions

- Will the owner add `drive.readonly` (a restricted scope) to the Google project for phase 09? Does Picker folder selection with `drive.file` cover the files inside the folder? `[UNVERIFIED]`
- For phase 10, which option does the owner want: that account's Drive, a Takeout archive, or the Picker?
- Is a menu-bar progress line wanted during imports? Not in this round; Settings and activity only.
