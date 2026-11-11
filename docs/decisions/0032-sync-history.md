# 0032 Sync history: an append-only transfer log written by a trigger, backfill runs, and a History window

- **Status:** Accepted
- **Spec refs:** issue #82 (scope agreed by the owner on 2026-11-11); FR-47 and FR-76 (integrity results are now kept per file); FR-63 (activity is unchanged)
- **Review trigger:** thumbnails in the history (deferred), a continuous source other than Photos, or the history table growing past what paging by index serves

## Context

The owner wants to look back at what was synced: the Photos files at each destination, each backfill run and its files, and the files of each one-time import with their result and reason. `upload_job` keeps only the latest state of each (file, destination), with `updated_at` overwritten on every change, and backfill jobs had no notion of a run. `import_item` already keeps every file of an import. The scope also asks for search and filters, per-destination status, readable reasons, retry, Show in Finder / Open on Drive, run summaries, CSV export, a daily timeline, files deleted from Photos whose backup is kept, and the last integrity check of each file. File names must stay out of logs, activity, notifications and sidecars.

## Decision

- **`transfer_event`, append-only, one row per outcome of an original-file job:** `uploaded` (the destination had no copy from this job before), `updated` (an edit replaced it), `failed` (the job enters `deferred`; the same failure repeated is not written again), `skipped`, `cancelled`. Sidecars are left out. Each row keeps the file, destination, source, the job's origin and backfill run as they were, the file size, the machine reason and the error's case name, the time, and whether it is approximate.
- **Written by a trigger on `upload_job`** (`upload_job_history`), like the v3 snapshot counters: the row is inserted by the statement that changes the job, so no outcome can be lost or recorded for a change that was rolled back, whichever code path writes the job. Recovery that matched a file already at the destination writes nothing (the job never was `uploading`).
- **`backfill_run` and `upload_job.backfill_run_id`.** A run groups backfill jobs of one cause: `library` (old photos found by the scan and classification), `settings` (the owner widened settings, a scope or rules), `destinationAdded`, `recovery`, and the seeded `beforeHistory`. A job joins the open run of its cause when it is created or reinstated as an original-file backfill job; a run is created with its first job. An owner command closes the open run of its own cause first, so each command is a run of its own. A drained cycle finishes runs with no backfill job pending or uploading; failed files do not hold a run open, and retrying them (from History or by the 24-hour sweeper) reopens it. A run whose jobs were deleted with their destination finishes.
- **`integrity_check`** keeps the latest result (`intact`, `hashVerified`, `missing`, `sizeMismatch`, `hashMismatch`) and time per (destination, file). A missing file's result is written with its `missingRemote` mark. The trigger deletes the result when an upload of the file finishes: it described a copy that is gone (re-upload) or older (edit). `intact` is shown as "vẫn còn ở đích" (present), only `hashVerified` as "còn nguyên".
- **Old data:** the migration copies each `done` original-file job as an approximate `uploaded` row at its `updated_at` (shown with "≈"), and puts every existing backfill job in one approximate `beforeHistory` run. Seeding skips what exists, so it is idempotent. Files already failed or skipped before the upgrade have no row, but a run counts them from `upload_job` for "retry failed files".
- **Queries** are paged by `(at, id)` newest first, 200 rows a page, and walk an index (`transfer_event(source_id, at)`, `(run_id, at)`, `(outcome, at)`, `(job_id)`, `import_item(source_id, state, rel_path)`); search folds case and diacritics through a `pv_fold` SQL function. The daily timeline sums 15-minute UTC slots that the app assigns to local days, exact in every time zone and across DST.
- **Retry** uses the owner's existing transitions only (`retryDeferred`, `retrySkipped`); it never deletes anything at a destination and never touches the Photos library. Retrying a file too large for the disk re-arms it at every destination that waited for it. Files an import could not read are retried by importing the folder again.
- **Kept forever**, about 100 bytes a row.
- **Privacy:** names are read from the local database into the History window and into a CSV the owner saves through the save panel; the new engine code logs counts and error types only. A test runs uploads, failures, a retry and an integrity check and finds no file name in the log or the activity list.

## Alternatives

- **Write the row in Swift next to each state change.** Every write path (upload, recovery, cancel, sweeper, retries) would have to remember it; a trigger cannot be forgotten and the codebase already keeps counters this way.
- **Derive history from `upload_job` alone.** It keeps one state per file and overwrites the time; edits, failures before a success, and runs cannot be told apart.
- **One run per backfill origin, with no owner-command boundaries.** A scope widened during the first backfill would merge into it, and "each time the owner starts one" would not hold.
- **Bucket the timeline by local day in SQL.** SQLite has no time-zone rules, so days would be wrong across DST.

## Consequences

- One extra insert per outcome, not per progress update; the trigger's `WHEN` clause skips every other update.
- The first launch of this version copies the done jobs once, after the usual pre-migration backup.
- A row's destination name comes from the destination as it is now; rows of a removed destination say so. Google Drive keeps one id, so rows of a removed Drive show under a Drive added later.
- Integrity results are deleted with a destination's jobs (removal, root or account change).
- "Deleted from Photos, backup kept" lists only uploads whose job still holds a copy; a photo deleted before it went up is not shown there.
- A rules change of one destination joins the shared `settings` run, which names no destination. Old photos that turn up after a `library` run finished start a new, small `library` run, so a finished run's span and totals do not change weeks later.
- Retrying a file of a cloud import whose grant was released (no file of it was pending, deferred or missing) asks the owner to sign in again, as an upload repeated after a lost file does (0030).
- Thumbnails (scope item 11) are not part of this decision.
