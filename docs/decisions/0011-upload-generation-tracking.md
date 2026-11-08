# 0011 Upload generation tracking: `done_gen` is the generation uploaded, not `target_gen`

- **Status:** Accepted (deviates from spec §8.3, literal rule)
- **Spec refs:** §8.3 (`done_gen = target_gen`), FR-46, T30b
- **Review trigger:** none expected; the rule is covered by state-transition tests

## Context

Spec §8.3 sets `done_gen = target_gen` when a job becomes `done`. If an edit lands while an older upload is still running, the older upload finishing would mark the newer edit as done. The newer content would never be uploaded (T30b).

## Decision

Implemented in `JobTransitions.swift`:

- `pending → uploading` captures `uploadingGen` from the current generation.
- `uploading → done` sets `doneGen = uploadingGen ?? targetGen`, then clears `uploadingGen`.
- A content change raises `targetGen = max(targetGen, contentGen)` without touching an upload that is in flight.
- A job is refreshed when `doneGen < targetGen`.

## Consequences

- No edit is lost: the last generation is always uploaded again if an earlier upload finished first. The intent of §8.3 ("không bao giờ mất bản cập nhật cuối") is kept.
- The `upload_job` table needs the `uploading_gen` column (spec §8.2 does not list it). It is part of the Store schema.
