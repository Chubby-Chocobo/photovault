# Phase 1: Store — schema, recording, queries

- **Touches:** `Sources/PhotoVaultStore/Schema.swift`, new `Schema+TransferHistory.swift`, `JobRepository.swift`, new `BackfillRunRepository.swift`, `HistoryRepository.swift`, `HistoryRepository+Runs.swift`, `ImportHistoryRepository.swift`, `IntegrityCheckRepository.swift`; `Sources/PhotoVaultCore/Entities/UploadJob.swift`, new `Sources/PhotoVaultCore/Models/HistoryModels.swift`; `Tests/PhotoVaultStoreTests/TransferHistory*Tests.swift`.
- **Acceptance:**
  - `v8-transfer-history` only adds: a column, tables, indexes, triggers, seed rows.
  - The trigger writes exactly one row per outcome (plan decision 1) in the job's own statement; a rolled-back transaction leaves neither.
  - Seeding twice gives the same rows; seeded rows are approximate; old backfill jobs share one `beforeHistory` run.
  - Paged event, run and import-item queries use an index on a table of 200k+ rows (`EXPLAIN QUERY PLAN`: no full scan of the history table, no temporary B-tree for the order).

## Steps

1. Tests first: outcome rows per transition, repeat suppression, rollback, seed idempotence, migration over a v7 database, query plans.
2. Migration and triggers; `UploadJob.backfillRunId` saved and decoded.
3. `BackfillRunRepository`: `runId(for:trigger:destination:now:)`, `close`, `finishSettled`, `reopen`.
4. Query repositories with keyset paging and filters.

## Rollback

The migration is additive; an older build refuses a newer database (`StoreError.newerSchema`) as today, and the pre-migration backup is kept.
