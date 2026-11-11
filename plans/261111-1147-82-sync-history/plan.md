# Sync history window (issue #82)

- **Status:** implemented; in review (PR #84)
- **Branch:** `feat/82-sync-history` from `release/0.7.0`
- **Scope:** History window with three tabs (Photos, Backfill, Import) and features 1–10 of the agreed scope. Thumbnails (11) are out.
- **Migration:** `v8-transfer-history` (additive)

## Phases

| # | Phase | Touches | Acceptance |
|---|---|---|---|
| 1 | [Store: schema, recording, queries](phase-01-store.md) | `Sources/PhotoVaultStore/Schema+TransferHistory.swift`, `Schema.swift`, `JobRepository.swift`, new `BackfillRunRepository`, `HistoryRepository`, `ImportHistoryRepository`, `IntegrityCheckRepository`; `Sources/PhotoVaultCore/Models/History*.swift`, `Entities/UploadJob.swift`; store tests | Migration additive; trigger writes one row per outcome inside the job's own statement; seed idempotent; paged queries use indexes (EXPLAIN QUERY PLAN test on a large table) |
| 2 | [Engine: runs, integrity, retry](phase-02-engine.md) | `EligibilityService.swift`, `SyncCoordinator.swift`, `SyncMilestones.swift`, `RecoveryService.swift`, `IntegrityChecker.swift`, `IntegrityLocal.swift`, `IntegrityDrive.swift`, `RootProblemService.swift` (RetryService), new `SyncCoordinator+History.swift`; engine tests | A row per outcome in real cycles; runs group their jobs and finish; per-file verify results; retry through existing transitions only; no file name reaches log or activity |
| 3 | [AppSupport: presentation](phase-03-app-support.md) | new `Sources/PhotoVaultAppSupport/History*.swift`; AppSupport tests | Filters, status and reason text, CSV escaping, timeline bucketing with injected calendar, run summaries; all strings `tr(vi:en:)` |
| 4 | [App: History window](phase-04-app.md) | `PhotoVault/Views/History/*`, `PhotoVault/App/AppModel+History.swift`, `WindowRequest.swift`, `PhotoVaultApp.swift`, `MenuBarLabel.swift`, `MenuBarActions.swift` | Window opens from the menu bar; tabs, filters, paging, detail, retry, reveal/open, CSV via NSSavePanel, chart; unsigned xcodebuild passes |
| 5 | Docs | `docs/architecture/system-architecture.md`, `docs/architecture/codebase-summary.md`, `docs/decisions/0032-sync-history.md`, `docs/decisions/README.md`, `README.md` (Using the app) | Tables and flow documented; decision record |

Order: 1 → 2 → 3 → 4 → 5. Tests are written first in each phase.

## Decisions

The owner asked us to choose wherever the scope left a choice open. Each choice and its reason:

1. **What counts as one event.** One `transfer_event` row per outcome of an original-file job (sidecars excluded: they are metadata, not the owner's files):
   - `uploaded`: an upload finished (`uploading → done`, or back to `pending` when a newer edit is waiting) and the destination had no copy from this job before (`done_gen` was 0; a re-upload after a missing file also counts).
   - `updated`: the same, when an earlier generation was already there (an edit replaced it).
   - `failed`: the job enters `deferred` (gave up for now; retried after 24 hours). The same failure repeated (same reason, nothing else recorded in between) is not written again, so a file retried daily does not add a row per day.
   - `skipped`: the job enters `skipped`.
   - `cancelled`: the job enters `cancelled` (scope narrowed, photo deleted, import cancelled).
   - Recovery that matched a file already at the destination writes no row: nothing was transferred.
2. **How rows are written.** By SQLite triggers on `upload_job` (as the v3 snapshot counters already are). The row is written by the same statement that changes the job, so it cannot be lost or left out of step whichever code path writes the job, and no Swift caller can forget it. The event keeps the job's origin and run as they were when the outcome happened (`OLD.origin`), the file size from `resource.size_bytes`, the machine reason (`state_reason`) and the short error code (`last_error`, a `DestinationError` case name, never a path).
3. **Backfill run.** A run is a group of backfill jobs created by one cause: `library` (old photos found by the first scan and later classification), `settings` (the owner widened settings, a scope or rules), `destinationAdded` (one per destination added), `recovery` (files a destination recovery found missing), and the seeded `beforeHistory`. A job gets the run when it is created or reinstated with a backfill origin (`upload_job.backfill_run_id`). Runs are created lazily on the first job, so a command that adds nothing leaves no empty run. An owner command closes the open run of its own cause first, so each command starts its own run; classification-driven `library` runs are not split by unrelated setting changes. A run is finished when it has no job pending or uploading at the end of a drained cycle (a failed file does not hold it open for 30 days); retrying its files reopens it until they settle again.
4. **Seeding old data.** The migration copies every `done` original-file job into `transfer_event` as `uploaded` at its `updated_at`, marked `approximate = 1` (shown as "≈"). Every existing backfill job joins one `beforeHistory` run, also approximate, spanning the earliest to the latest of those times. Seeding skips jobs that already have a row and a run that already exists, so running it twice changes nothing.
5. **Integrity results.** `integrity_check` keeps the latest result per (destination, file): `intact`, `hashVerified` (re-hashed in the local sample), `missing`, `sizeMismatch`, `hashMismatch`, with the time. Missing files are written in the same transaction that marks the job `missingRemote`; intact ones are written in batches after the check. Drive files under a trashed folder are not judged and keep their earlier result.
6. **Retry.** "Retry" uses the existing owner transitions only: a `deferred` job gets `retryDeferred` (clearing export or disk counters as the existing retry does), a `skipped` job gets `retrySkipped` (its remote id is kept, so nothing is uploaded twice). Other states are left alone. For one file, all failed files of a backfill run, or all failed uploads of an import. A file of an import that could not be read stays as it is: the existing way back is importing the folder again (duplicates are recognised). Nothing is deleted anywhere and the Photos library is not touched.
7. **Open on Drive / Show in Finder.** Drive: `https://drive.google.com/file/d/<remote id>/view`, built only when the id is made of Drive id characters. Folder or NAS: the destination's bookmark is resolved and the job's relative path appended; a path with `..`, `.`, empty or absolute parts is refused. Both only for a job that is `done`.
8. **Timeline.** The store sums uploaded and updated rows per 15-minute slot in UTC; the app assigns each slot to a local day with the calendar it is given. Every real UTC offset is a multiple of 15 minutes, so days are exact in every time zone, across DST changes, with at most 96 slots a day to read.
9. **Indexes and paging.** Lists use keyset paging on `(at DESC, id DESC)` with pages of 200. Indexes: `transfer_event(source_id, at)` for the Photos tab, `transfer_event(run_id, at)` for a run, `transfer_event(outcome, at)` for the timeline and outcome filters, `transfer_event(job_id)` for the repeat check and per-file lookups, `upload_job(backfill_run_id)`, and `import_item(source_id, state, rel_path)` for the Import tab. Name search and media/capture-date filters are applied on the rows the index walk reads. Every query runs on GRDB's reader, off the main thread.
10. **Retention.** Kept forever (owner decision); rows of a removed destination stay and show "removed destination".
11. **CSV.** The rows of the current filter (all pages, not only the ones on screen), written only after the owner picks a file in the save panel. UTF-8 with a byte-order mark (so spreadsheet apps read Vietnamese names), CRLF line ends, RFC 4180 quoting (a field with a comma, quote, CR or LF is quoted, quotes doubled). A field that starts with `=`, `+`, `-`, `@`, tab or CR gets a leading `'` so a spreadsheet does not run it as a formula. Columns, Photos and Backfill: time, approximate, file, destination, result, cause, size in bytes, capture date, reason. Import: file (relative path), result, size in bytes, reason, duplicate of.
12. **Where history appears.** File names and paths are shown only in the History window and in a CSV the owner saves. Recording, retry and integrity code log counts and types only; activity and notifications are unchanged.

## Risks

- Trigger cost: one extra insert per outcome (not per progress write); the trigger's `WHEN` clause skips every other update.
- A large first migration: one `INSERT … SELECT` over `upload_job`; the database is backed up before migrating, as today.

## Unresolved questions

None open.
