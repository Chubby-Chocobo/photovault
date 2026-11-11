---
title: Pipelined cloud import (issue #69)
status: done
branch: feat/69-pipelined-cloud-import
base: release/0.6.0
---

# Pipelined cloud import

## Goal

A round of the sync cycle reads the next files (import reads, exports into staging) while the upload pass sends what
is already staged, so a cloud-to-cloud import takes about max(download, upload) instead of their sum.

## What the code does today (verified)

- One round: `pickUpChanges` → `classifier.runPass` → stage `.classify` (`ImportStage`: up to `importBatchGroups` /
  `importBatchBytes` read and hashed, then committed) → `exporter.runPass` (downloads into staging, capped by
  `ResourceGuard` at `stagingSoftLimitBytes` plus the disk watermarks) → `.editGate` → `uploader.runPass` → organization
  stages → `releaseUnneeded` / `expireIdle`.
- A cloud file is downloaded twice: `inspect` reads it to a scratch file to hash it and deletes it; the export downloads
  it again into staging. Both are download work, so both belong on the "read" side of the overlap.
- `UploadAttempt.run` reads the job as `pending`, then applies `startUpload` in a later transaction. Nothing changes the
  job plan of an in-flight upload today, because plan changes run between passes. `ImportCancellation.apply` cancels
  `pending` jobs, so it should not run while an upload pass is running (a job read as `pending` and cancelled before its
  `startUpload` would hit an invalid transition; `applyIfValid` absorbs it, but the attempt is wasted and logged as an
  unexpected error).
- `UploadCompletion.commit` already compares the layout and queues a move when the placement changed during an upload,
  so an import commit that re-counts a day while an upload runs is handled.
- The Drive write rate and daily cap live in `GoogleDriveDestination`; per-destination upload concurrency lives in
  `UploadRunner`. Neither depends on what runs beside the upload pass.

## Design

Round, after this change:

0. Cycle checks also reset resources left `exporting` (an export cut off by an error in the upload half cannot record
   its own end: its task is cancelled and GRDB refuses writes from a cancelled task).
1. Pass boundary (owner commands run), pause check, `pickUpChanges`.
2. Cancel bookkeeping for imports whose cancel was asked (in memory or stored) — no upload is running here.
3. `uploadsAllowedNow`, `ResourceGuard.enforce`, stage `.editGate`.
4. Overlap, in one task group, both halves joined before the round goes on:
   - upload half: `uploader.runPass(gate:)` (only when uploads are allowed), sending what is staged now and what the
     read half stages meanwhile;
   - read half: `classifier.runPass`, stage `.classify` (`ImportStage`), `exporter.runPass`, stage `.export`.
5. Stages `.fanOut`, `.sidecarsAndViews`, `.moves`, `.placeNamer`; staging release; progress check.

## Decisions

- **Overlap unit is the round.** Import of batch N+1 and its export run while batch N uploads; the join at the end of
  the round is the look-ahead bound: the read half reads at most one import batch per round and its exports stop at the
  staging cap, so it can never run more than one batch ahead of an upload pass. No new tuning knob.
- **Staging bound unchanged.** Exports keep going through `ResourceGuard.admit` (staged + in-flight bytes below
  `stagingSoftLimitBytes`, disk watermarks); import reads keep `hasRoomToDownload`. Uploads free staging per file
  (`releaseUnneeded(asset:)`), which lets the exporter admit more within the same round.
- **No plan changes beside uploads.** The import stage no longer runs the cancel bookkeeping itself; it stops reading
  the cancelled import and reports work, and the cycle settles the cancel at the start of the next round (step 2) or the
  owner's `cancelImport` settles it at the pass boundary, whichever comes first. The exporter skips candidates of an
  import whose cancel was asked, so a cancelled import's files are never downloaded again.
- **New Photos assets first.** A round that follows new Photos work (scan, change tracking or reconciliation at cycle
  start, or changes picked up at the boundary) runs the read half first and the upload pass after it, so the upload
  ranking sees the new photos exported, as in the sequential round. Found by `aNewPhotoIsUploadedBeforeTheRestOfTheBacklog`.
- **Edit gate moves before the overlap.** It used to run between export and upload; running it before the round's
  upload keeps "edits are decided before the upload" while the upload no longer waits for the export.
- **Errors.** The first error from either half cancels the other (task-group semantics) and ends the cycle as before.
  Uploads cut off this way stay `uploading` and are settled by `resolveInterrupted` / startup recovery, as for any
  cancelled upload. A crash point in one half leaves the database as a crash at that moment would.
- **Pause and commands.** The upload gate is unchanged (pause, network, power, waiting commands, Photos changes pending);
  the import stage still yields after the group in hand; the export pass now also stops dispatching on pause or a waiting
  command (it used to run to the staging cap first). A pass cut short this way counts as progress, so the cycle reaches
  its boundary (command runs, or `.paused`) instead of ending as drained.
- **Existing tests that pinned the sequential order.** Three cancel tests crashed on the second group's commit and
  expected the first file already uploaded; they now read through `FirstUploadFirstSource`, which makes later reads wait
  for the first upload (same scenario, order fixed by a signal). `changingHiddenUploadReevaluatesOnce…` accepts that the
  hidden photo may upload after the day split (no move) as well as before it (moves).
- **Out of scope (follow-up):** keeping the hashed scratch copy as the staged file would remove the second download of
  every cloud file; it changes the adapter contract and the crash rules, so it gets its own issue.

## Tests (written first)

`PipelinedImportTests` with a fake slow cloud source and a gated fake destination, signals only:
- the upload of batch 1 is in flight when the read of batch 2 starts; peak staged bytes stay under the cap;
- pause during the overlap: no new upload, read or export starts, the cycle ends `paused`;
- cancel during the overlap: the read in hand stops, nothing more is read or exported, the import ends cancelled, the
  upload in flight completes;
- crash in the read half with uploads in flight, and in the upload half with a read in flight: after a restart every
  file reaches the destination exactly once and staging is empty;
- an export cut off by an upload-half error is done again by the next cycle without a relaunch;
- a waiting command runs before the next export starts.

## Acceptance

- `swift test --parallel` green; new tests green over repeated runs; app builds with `xcodebuild`.
- `docs/architecture/system-architecture.md` describes the overlapped round.
- PR into `release/0.6.0`, "Closes #69", CI green.
