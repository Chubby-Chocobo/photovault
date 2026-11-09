# 0024 Several sources, one layout: the source model and the one-time folder import

- **Status:** Accepted
- **Spec refs:** §2, §3, §8.1, §8.2, §8.4, §8.8, §8.12, §15 (amended); new FR-110 to FR-116 (§4.13)
- **Review trigger:** a continuous non-Photos source lands (Dropbox, Flickr, another Google account), the owner reports a wrong "already backed up", or large imports crowd out new Photos uploads or drain the battery

## Context

On 2026-11-09 (issue #17) the owner said Photos stays the main source with a steady flow of new photos, and that other long-lived sources will follow (Dropbox, Flickr, another Google account) plus one-time jobs that import everything from a folder (on this Mac now; on Google Drive or another cloud later). Whatever the source, photos land in the destination organised the same way. Spec §2 listed Dropbox and several Google accounts as non-goals; the issue is authoritative over it.

## Decision

- **Sources.** `asset.source_id` (default `photos`) says where an asset came from. `ContentSource` reads resource bytes for export; `SourceRegistry` maps a source id to its adapter and always holds Photos. Export and recovery read through the registry. Scanner, change tracking, reconciliation, cloud-id backfill, the edit gate and classification stay Photos-only and ignore other sources.
- **One-time folder import.** Settings › Nguồn › Nhập ảnh… takes a read-only security-scoped bookmark of a folder. `ImportStage` runs in the cycle: it lists the folder recursively, groups files (RAW+JPEG by name, Live Photos only by Apple content identifier), reads EXIF or QuickTime metadata, hashes each file and ingests each group in one transaction. After that the normal pipeline runs: placement, export to staging, fan-out, sidecars, views.
- **Content keys.** An imported asset's key is `x:<sha256 of its primary file>`. The same bytes get the same key in every job, so a re-run import and overlapping folders dedupe, and recovery (8.15) can match files after a database loss. Continuous non-Photos sources will use `s:<sourceId>/<itemId>` because their files can change.
- **Dedupe.** A file is a duplicate when its key exists, when a live asset has a resource with the same SHA-256, or when a live asset has the same capture second, original stem (case-insensitive) and pixel size (either order) or duration (±0.5 s). A duplicate is counted, not ingested. Two gaps remain: a Photos asset that a destination's scope excludes blocks its folder copy too, and a photo added to Photos after it was imported is uploaded again.
- **Imports are new arrivals.** `inserted_at` is the ingest time and jobs are `incremental`: they reach `newOnly` and `since` destinations and skip the backfill bucket and the AC-power gate. The disk guard still applies.
- **Date, place, category.** EXIF `DateTimeOriginal` (+ offset, else the archive timezone), then the QuickTime date, then the earlier of the file's creation and modification dates; location from EXIF GPS or ISO 6709; category from `CategoryClassifier` with the metadata already read (screenshot = EXIF `UserComment` "Screenshot"; a parent folder named like a chat app counts as that album).
- **Cancel.** Remaining files become `cancelled`; imported assets with a job that has not finished are treated as deleted (pending jobs cancelled, uploaded files stay). Importing the same folder again revives them.
- **Sidecar.** Imported assets add `"source": {kind, name, path, dateSource}`; `localIdentifier` is `<sourceId>/<relative path>`. Photos sidecars are byte-identical to before.
- **Privacy.** The activity summary and logs carry counts only. The folder name shows in Settings, the menu bar card and the completion notification, never in logs or activity.
- **Google Photos API.** Another Google account cannot be a continuous Google Photos source: since 2025-03-31 the Library API reads only app-created media. The options are that account's Drive, a Takeout archive, or the Photos Picker.

## Alternatives

- Generalise `PhotosSource` into a multi-source protocol used by every pass: wide change to Photos semantics for no gain this round.
- A separate pipeline for imports: would need its own placement, names, views and sidecars.
- `s:<sourceId>/<relative path>` keys for imports: the same bytes would get different keys in different jobs.
- Rate-limit imports like backfill: the gates protect against Photos downloading originals, which a local folder does not do.

## Consequences

- Migration `v5-sources` is additive (a column with a default, two tables, two indexes). Undo = restore the `DatabaseBackup` copy taken before the update, or the reset of decision 0023.
- Photos still needs access and a baseline before an import runs, because both share the cycle.
- Each imported file is read twice (hash at ingest, copy at export). A slow NAS pays the double read.
- The bookmark stays after completion so a later re-export works; a "remove from list" action is deferred.
- A folder that goes away after ingest holds only its own job (`offline`) and resumes by itself; a file that is gone becomes a skipped job.

## Not in this round

Continuous non-Photos source runtime, Google Drive folder import, another Google account, Dropbox and Flickr. They are phases of the same plan and need the owner's setup first (OAuth scopes, app registration, API keys).
