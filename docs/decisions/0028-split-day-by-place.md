# 0028 Split a camera day into one folder per province

- **Status:** Accepted
- **Spec refs:** FR-40, FR-81, FR-83, §8.2, §8.4 step 9, §8.7, §8.11, §8.15, T28 (all amended)
- **Review trigger:** owner feedback on emptied folders or on the 500-move pass cap; Apple changes the province data again

## Context

A day with photos from several provinces used to lose its place name (`unnamed`). On 2026-11-10 (issue #27) the owner chose: split by province, key `isoCountryCode|administrativeArea` in `en`; a photo without usable GPS joins the group of the nearest photo in time; no minimum group size; A → B → A is two groups; folders sort by name with no ordinal; files already backed up are moved; splitting waits until the day ended at least 6 hours ago (FR-83); Screenshots and Saved are never split and the views do not change.

## Decision

- **Data:** `asset.place_slot` (NULL = main folder `camera/<day>`) and `day_place(day, slot, place_key, place_name)` for extra folders (migration `v6-day-place`). The main folder stays in `day_stat`. A one-province day writes no new rows and its layout is byte-identical to before.
- **Paths:** an extra folder is a sibling, `camera/<day>@<slot>`, shown as `YYYY-MM-DD <place>`. The slot is `p` plus 12 or more hex digits of SHA-256 of the province key, or `r` plus those of a recovered folder name. `@` matches neither `LegacyLayout` nor `LegacyRootProbe`.
- **Grouping** (`PlaceSplitPolicy`, pure): while the cells that have an `en` answer show at most one province, the old single-place rule applies unchanged. A box over 300 km with unanswered cells waits (`waitingGeocode`) instead of reading as unnamed. Once two provinces are known, every cell needs its `en` answer, then each group is named alone. Photos without GPS, in a sea cell, or hidden while hidden upload is off join the nearest identity-carrying photo in time (a tie goes to the earlier photo, then the smaller id).
- **Folders** (`DaySlotPolicy`, pure): four passes over all groups, largest first: by name, by key, the free main folder, a new folder. The name index includes names still on disk while a rename retries and names vacated in the same run, so two folders never share a name. A group whose name is still held by another folder is deferred: it keeps its current slot and the day is evaluated again after the renames ran.
- **Writing** (`DaySplitWriter`, in `PlaceNamer`'s transaction): slots, names, renames, and one `moveFile` per uploaded file and sidecar whose asset changed slot. `MoveWorker` runs at most 500 moves per destination per pass (`EngineTuning.maxMovesPerPass`); the cycle repeats rounds while there is progress.
- **Late photos** placed on an already split day take the slot of their cell's province, otherwise the slot of the nearest photo in time. They have no file yet, so nothing moves.
- **Country-only geocode mode** freezes splits: a day with `day_place` rows is left as it is; other days are named by the single-place rule. Without this, entering and leaving the fallback would move every file of every split day twice.
- **Recovery** binds each listed day folder (`DaySlotBinding`) by folder id, then by display name, then by fallback (`pvLogical` on Drive; the first folder by name is the main folder on a local destination, the rest `@r…`). A row whose folder is still listed is never re-pointed; a stale row (restored backup) is. Conflicts are refused, logged and reported. A recovered asset's slot comes from the folder of its primary file.
- **Upgrade:** a one-time pass (`kv.place_split_backfill`) re-evaluates every promoted day, because 0.3.0 stored multi-province days as `unnamed`. Changing hidden upload does the same once (`kv.place_hidden_basis`).
- **Downgrade guard:** `Store.open` refuses a database with migrations it does not know (`StoreError.newerSchema`).

## Alternatives

- Compute groups on the fly in the layout: files would move whenever a geocode answer changed, outside the 6-hour rule.
- Nest extra folders in the day folder or give every group a new path: the old folder would be emptied and never deleted.
- A suffix or ordinal for equal names: the owner rejected ordinals; equal names share a folder.
- Trash emptied folders: `Destination` has no delete.

## Consequences

- Deleted photos stay in the folder they were in when the day split: deleted Ninh Bình photos sit in the main folder named "Hà Nội". They never move.
- Emptied extra folders remain, and a later group with the same name reuses them.
- Country-only mode freezes splits; they resume when provinces are seen again.
- "Làm mới địa danh" re-asks every cell and may regroup a day and move files. It is the remedy for spurious splits when Apple's data before and after Vietnam's 2025 province merger disagree.
- The upgrade moves files of existing multi-province days: up to one Drive write per file, about 5 per second, in passes of 500. A fresh install or a large import uploads photos into the main folder first and moves the others once their cells are geocoded.
- Downgrading to 0.3.0 is unsafe: it ignores `place_slot` and would commit sidecar replacements against the main folder. Builds from this one on refuse a newer schema; 0.3.0 cannot be guarded.
- Two groups with the same display name share one folder, and groups over 300 km share one unnamed folder.
