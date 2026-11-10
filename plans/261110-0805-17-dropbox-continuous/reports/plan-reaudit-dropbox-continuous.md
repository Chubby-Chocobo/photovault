# Plan re-audit: Dropbox continuous source (revision 2)

Plan: `plans/261110-0805-17-dropbox-continuous/` (plan.md + phases 01–07) on `feat/17-dropbox-continuous` @ `1c92d25`. First audit: `reports/plan-audit-dropbox-continuous.md`. This is a design audit; no code was run. It also checks feat/27 (`photovault-27-split-day-by-place` @ `cc7afa0`) and branch `docs/future-continuous-sources` (`a5f6f98`).

**Checks run**
- `node .claude/skills/adf-plan/scripts/plan-phases.cjs --check plans/261110-0805-17-dropbox-continuous`: 7 phases, 0 problems, 1 warning (`status-unknown`: `on-hold` is not in the tool's status enum). The status is intended, so the warning only needs a note.
- About 45 file:line claims checked against the code. All hold.
- Facts confirmed against the code:
  - GRDB runs unapplied migrations in registration order, whatever their position (`DatabaseMigrator.swift:582-640`). `hasBeenSuperseded` flags only ids it does not know (`:556-559`). feat/27 calls it in `Store.open` (`Store.swift:34`); the base has no guard.
  - `RowDecoding.parse` throws `corruptRow` (`RowDecoding.swift:16`).
  - The snapshot already lists only `mode == .oneTime` imports (`SnapshotBuilder.swift:39`).

## 1. First-audit findings

| # | Verdict | Where resolved / what is left |
|---|---|---|
| C1 root replaced/deleted | RESOLVED | plan.md Decisions "Root guard and mass-removal brake"; phase 05 req. 6 (probe, `changes`, reset, deleted root/ancestor); phase 03 req. 1, 4 (reasons, brake); phase 03 `ContinuousFeedSafetyTests`; phase 05 root-guard tests. The brake has new problems, see I-6. |
| C2 retire while another row holds the bytes | PARTIAL | plan.md "Retirement hands an asset over"; phase 03 req. 6 and `ContinuousHandoverTests`; phase 04 req. 7. Two gaps remain: a hand-over into an `importing` one-time import never gets ingested (I-1), and `cancelImport` still retires without a hand-over (I-3). |
| I1 batch order, `stem (n)` primary key | RESOLVED | plan.md "Feed ordering, batching and crash safety"; phase 01 req. 5 (order, folded `(n)`); phase 02 req. 3 (compare-and-set, `isFree`); phase 03 req. 5. Pairs can still split, see M-5. |
| I2 stale inspect | RESOLVED | plan.md "Read hash = stored hash"; phase 01 req. 2; phase 04 req. 3; phase 05 req. 3 and hasher tests. |
| I3 settle delay splits pairs | RESOLVED | plan.md "Files wait one hour, per group"; phase 02 req. 2 (`HAVING MAX(COALESCE(seen_at,0))`, outer query returns all members). |
| I4 failed rows never retried | RESOLVED | plan.md "Failed files … retried daily"; phase 03 req. 3–4. Cadence problem: M-3. |
| I5 migration id and rollback | RESOLVED | plan.md "Rollback", "Migration id without a number"; phase 02 req. 1 and its risks. One wording fix: M-12. |
| I6 modified file = new asset (owner) | PARTIAL | Recorded as a *lead* decision with Review later: yes. It was not put to the owner, and it is missing from "Unresolved questions". The docs branch still calls option (b) "chưa được chọn". See M-14. |
| I7 downloads ignore network/power | RESOLVED | plan.md "Downloads follow the upload network and power rules"; phase 04 req. 2, 4. It conflicts with docs R10, see I-5. |
| I8 remove semantics (owner) | PARTIAL | Lead decision: "= cancel import, grant deleted" (plan.md, phase 04 req. 7, phase 06 req. 6). The owner was not asked, and the decision contradicts docs R12 ("grant giữ"), see I-5. |
| M1 `LIKE` / Unicode fold | RESOLVED | phase 01 req. 4; phase 02 req. 3 (`substr`, `path_fold`). |
| M2 returned re-downloads | RESOLVED | phase 01 req. 5 `returned(restore:)`; phase 03 req. 5–6. This holds for primaries only; companions are still downloaded again (M-7). |
| M3 orphan grants | RESOLVED | phase 06 req. 2. A safety condition is missing: M-10. |
| M4 `cancelImport` on continuous | RESOLVED | plan.md "Status model"; phase 04 req. 7. |
| M5 in-order delta | PARTIAL | phase 05 req. 5 adds compaction, but its rule "a later file wins" drops real deletions (I-2). |
| M6 recheck on waiting rows | RESOLVED | phase 06 req. 10 (`ready`). Rechecks still run while transfers are held: M-11. |
| M7 export hold flicker | RESOLVED | Accepted limit (plan.md "Accepted limits"; phase 07 FR-130). |
| M8 sidecar re-upload wording | RESOLVED | Acceptance 1. |
| M9 Photos access stops Dropbox | RESOLVED | Documented (plan.md "Where the feed runs"; FR-130). |
| M10 per-asset removal | RESOLVED | phase 04 req. 7 mirrors `cancelImport` asset by asset. |
| M11 `.item` YAGNI | RESOLVED | One test (phase 01 Tests). |

The test-matrix additions of the first audit are all present in plan.md "Test matrix".

## 2. New problems

### Important

**I-1. A hand-over into a one-time import in `importing` wedges that import.**
- `AssetHandover.requeue` (phase 03 req. 6 step 5; phase 02 req. 3) sets rows of an open one-time import back to `pending`.
- `ImportStage.advance` sends an `importing` source only to `finishWhenDone` (`ImportStage.swift:47`). That function returns false while any row is pending (`ImportStage+Completion.swift:14`), and nothing moves the source back to `scanning`. Only `resume` does that, and only from `offline` (`ImportStage.swift:55-63`).
- Result: the import never completes, and the handed-over rows are never read. The asset stays deleted, so the C2 loss returns for exactly the cross-source case.
- Removal hand-over has the same problem (phase 04 req. 7 step 3).
- Fix:
  - In the same transaction, `requeue` sets every affected one-time source that is `importing` to `scanning`.
  - Add a test: a one-time import is uploading (`importing`), its duplicate row is handed over, and the import ingests the row and then completes.

**I-2. Compaction drops a deletion when another file takes the same path.**
- The rule in phase 05 req. 5: "A file entry after a `deleted` for the same path wins."
- Cases where this goes wrong:
  - safe-save editors (write a temp file, delete the original, rename the temp);
  - deleting a photo and adding a different one with the same name;
  - deleting a folder and recreating it, all within one poll.
- In each case the old id's deletion disappears. The planner then sees a new id at a path whose live row still has `remote_path = P`. It emits `insert` at `stem (2).ext` (phase 01 req. 5). The old row stays live until the next complete listing:
  - its asset is never retired;
  - later destinations fail it as `resourceMissing`;
  - the new version is misnamed `(2)`.
- The rule is not needed for case-only renames. The planner already turns "a removal of an id that is listed again" into a move.
- Fix:
  - Phase 05: a `deleted` entry drops earlier entries at or under its path and is always emitted as `.tree`.
  - Phase 01: add a rule. A live row whose `remotePath == file.pathKey`, whose id is different and not listed elsewhere, is `removed`. The new id then becomes `reuse`. This also covers providers that never report the delete.
  - Phase 03: also fetch known rows by `remote_path IN (listed pathKeys)`. A slot found by folded prefix misses rows that moved into P.
  - Tests: delete and re-add with a new id in one delta; folder delete and recreate in one delta.

**I-3. `cancelImport` still retires an asset that a watched source holds.**
- Case: a one-time import's asset K has a continuous `duplicate` row (the watched folder was added while the import ran, or overlaps it). Cancelling the import deletes K and cancels its pending jobs (`SyncCoordinator+Imports.swift:67-77`).
- The continuous row stays `duplicate` and is never read again. The file in the watched folder is never uploaded.
- The plan names closed imports as non-*holders* only (plan.md Retirement "Why"). The retiring side of `cancelImport` is not covered, and phase 04 already edits that function.
- Fix:
  - `cancelImport` calls `AssetHandover` for each asset it deletes, excluding its own rows. Revival keeps the placement, so no original is uploaded twice.
  - Add a test.
  - Alternatively, list it in FR-130 as a known limit.

**I-4. Phase 03 cannot pass without phase 04's mode filter.**
- `ImportStage.run` takes every `kind.isImport && status.isOpen` row (`ImportStage.swift:24-26`).
- For a continuous row, `SourceRegistry.folder(for:)` returns nil (a `ContinuousSource` is not a `FolderImportSource`, `SourceRegistry.swift:15`), so the stage calls `holdForSignIn` (`:30-36`). The source flips to `offline/signInRequired` on every cycle after the feed set it to `watching`.
- The `mode == .oneTime` filter only arrives in phase 04 req. 2. Phase 03's `ContinuousFeedTests` (transitions and the return to `watching`) and the hand-over tests run before it.
- Fix: move the filter (one line) into phase 03. `ImportStage.swift` is already in its touches.

**I-5. Conflicts with branch `docs/future-continuous-sources`.**

That branch is the doc plan.md Decisions point to.
- **Decision number.** It adds `docs/decisions/0029-photos-only-continuous-source.md`. Phase 07 also takes 0029. Use the next free number (0030 after #27's 0028), and say in it that it supersedes 0029.
- **Roadmap file.** It creates `docs/requirements/roadmap.md`. plan.md "Provider mechanism" says "no `roadmap.md` is created; spec §15 is the existing roadmap", and phase 07 req. 1 edits §15 only.
- **Provider guide.** `docs/architecture/continuous-source-extension.md` (R1–R15, provider table) duplicates the planned `adding-a-source-provider.md`. Phase 07 should update that doc instead of adding a parallel one (DRY). It is missing from phase 07 touches.
- **Contradictions with the plan:**
  - R10: "Tải xuống (cả để nhập lẫn đọc feed)" is gated. The plan keeps the feed listing ungated.
  - R12: "grant `import-<id>` giữ như với nhập một lần". The plan deletes the grant.
  - The doc lists a **Thử lại** button. The plan rejected it.
- Fix: correct R10, R12 and the button in the docs branch now (it is meant to be living truth and merges first), and update phase 07 touches and requirements.

**I-6. The brake allowance can be erased by the confirm itself.**
- `confirmLargeRemoval` "records a one-shot allowance in the holds, sets `watching` and clears the cooldown" (phase 03 req. 2). The only cooldown-clearing API is `ImportHolds.clear` (`ImportHolds.swift:50`), and req. 3 says `clear(id)` "forgets all of them", allowance included.
- Read literally, the confirm erases its own allowance. The brake then trips on every feed until **Gỡ**: a source wedged forever.
- Smaller gaps:
  - The allowance has no bound. It approves *any* removal count in the next feed, including a reset relist or a different bug.
  - It is lost on relaunch and on sign-in (`resumeImportAfterSignIn` calls `clear`, `SyncCoordinator+Imports.swift:40`). The owner must then confirm again, which is not a wedge.
- Fix:
  - Add `ImportHolds.clearCooldown(id)`, and have `confirmLargeRemoval` use it.
  - Store the removal count at the trip, and allow at most that count plus a small margin.
  - `confirmLargeRemoval` acts only when the reason is `largeRemoval`.
  - Test: confirm, then a sign-in before the next feed, then the brake trips again and is not wedged.

### Minor

- **M-1. No cooldown after a brake trip.** Phase 03 req. 4 sets none. Every poll then reads the whole delta again (on a reset, every row of the source) and plans it again. Hold the source with a longer wait (for example `signInBackoff`).
- **M-2. A held source is silent.** A source held for `largeRemoval`, `rootChanged` or `signInRequired` stops backing up new photos, and plan.md UI says "No notification". The plan should state that this is accepted, or notify after a threshold. With `rootChanged`, a common "rename Camera Uploads" can also be followed: `get_metadata(rootId)` gives the new path, and relative paths stay valid. Today the only exit is **Gỡ** + re-add, which downloads the whole library again.
- **M-3. Daily retry can become hourly.** A busy or unavailable group is given up only after 10 tries and 24 h (`ImportHolds.swift:24-25, 96`). By then the 24 h `failedRetryDue` is due, so a stubborn file is retried about hourly forever. Note the retry time when rows are marked failed, or accept and document it.
- **M-4. The `changed` group suffix grows and splits pairs.** It is `"#" + contentHash.prefix(12)` appended to the current key (phase 03 req. 5): `g#a#b…` after each edit. A RAW and its JPEG changed together get different suffixes, so they become two assets. Derive the key from `FolderItemGrouper.groupKey(rel_path)`, plus one token shared by the base group within the plan.
- **M-5. `stem (n)` is chosen per file.** If `IMG (2).JPG` exists, a new RAW+JPEG pair gets `IMG (2).CR2` and `IMG (3).JPG`, which do not pair (phase 01 req. 5). Choose n per base group.
- **M-6. Batches split between paths, not groups.** After a crash or `busy` mid-first-listing, half a pair committed with `seen_at = NULL` is ready at once. Split only between group keys.
- **M-7. `returned(restore:)` covers only the imported primary.** Companions go pending and are downloaded again, so the test "move out and back … restored, no download" fails for pairs. Restore every row of the asset whose hash is unchanged, or narrow the test.
- **M-8. A failed restore still marks the row as primary.** When `AssetHandover.restore` is a no-op (the asset was taken over by another source), `restoreReturned` has already made the row `imported` primary of K. Mark it `duplicate` of K instead.
- **M-9. Removal step 3 excludes nothing.** Phase 04 req. 7 step 3 (`handOver`) does not exclude the source's own rows, and step 1 (`cancelPending`) has already run, so an own holder requeued then stays pending in a cancelled source. Exclude own rows in step 3 too. Also, `Set<(SourceID, String)>` (phase 02 req. 3) is not Hashable in Swift; name a struct.
- **M-10. The orphan sweep can delete every grant.** It must skip when the source read fails. `AppEnvironment` reads rows with `(try? …) ?? []` (`AppEnvironment.swift:190`), and an empty list would delete every `import-*` grant, including those of finished imports.
- **M-11. Idle rechecks while transfers are held.** The 5-minute recheck on `ready > 0` (phase 06 req. 10) still runs while `TransferGate` is closed: about 12 idle cycles an hour on battery or a hotspot. Skip it while `EngineSnapshot.uploadsHeld` (`EngineSnapshot.swift:130`) is set.
- **M-12. Rollback wording.** "its newer-schema guard makes an older build refuse the database" holds only for builds that have the guard. 0.4.0 has none (no `hasBeenSuperseded` on the base) and fails with `corruptRow` instead.
- **M-13. Spec and text fixes.**
  - Phase 06 req. 10: "the 15-minute timer" is the disk-recheck `Timer` (`SyncScheduler.swift:33`); the background activity is hourly. Say so: the condition becomes `diskLow || needsSourcePoll`.
  - The `rootChanged` label in plan.md (Outcome, manual E2E: "Thư mục đã đổi trên Dropbox") and phase 06 (E2E: "Thư mục đã bị đổi tên…") differ. Name one as the label and one as the detail.
  - Phase 07 does not edit spec §2: item 9 (line 32), and line 35 "Không làm: … S3, OneDrive" plus "Nguồn liên tục từ Dropbox … để sau". These contradict the new FRs and the §15 roadmap.
  - Phase 06 `addDropboxSource` must also write `remoteItems: [path]`, `account` and `sidecarName`, as `AppModel+CloudImports.swift:98` does. The launch factory needs `rootPath`.
- **M-14. Owner questions are missing.** Add I6 (modified file = new version) and I8 (remove = cancel, grant deleted) to plan.md "Unresolved questions" for the owner on resume.
- **M-15. The brake rationale overclaims.** "The brake also catches provider bugs no rule foresees" is true for removals only. A hash-signal bug produces `changed`, which retires assets but costs only a re-download, because the same bytes revive under the same `x:` key. Say so in the Why.

### Questions the lead asked

- **Can the brake wedge a source forever?** As written, yes: I-6. With the fix, no. A trip waits for the owner (M-2), and the cursor stays uncommitted, so nothing is lost.
- **Does a confirm race with a cursor reset?** No race: commands run in the lane between stages. The risk is that the allowance has no bound (I-6).
- **Does AssetHandover loop between two sources?** No. A retire only follows a feed action, and the first holder to ingest revives K. Later holders see K live under an open source and become `duplicate` (`ImportDedupe.swift:40-46`).
- **Cancel and closed imports?** See I-1 and I-3. Closed imports as non-holders are documented.
- **Does TransferGate stall Photos or imports?** No:
  - Exports still run when uploads are held (`SyncCoordinator+Cycle.swift:167`), and the gate only removes continuous assets from the candidates.
  - Photos and imports are untouched.
  - Recovery reads (`RecoveryMatcher.swift:207`) are not gated. They are rare, so this is acceptable.
- **Daily retry?** See M-3.
- **Migration vs feat/27?**
  - With either merge order, the ids are both kept, both migrations are additive and independent, and GRDB applies whichever is missing. feat/27 changes `AssetFinalizer` internally but keeps its signature.
  - A database touched by a branch build is refused by any build that lacks its id. That is why the plan's "E2E on the final build or a copy" rule is needed.
- **Stale terms?** None. `s:` and `v7` appear only under Alternatives and in phase 07's instruction to drop the `s:` sentence.

## Unresolved questions

- Owner: confirm I6 and I8, or reopen them (M-14).
- Who corrects R10 and R12 on `docs/future-continuous-sources`, and does it merge before this plan resumes (I-5)?
- Does a Dropbox safe-save keep the file id or create a new one? I-2 handles both; the owner's E2E should include editing a file in place.

Counts: Critical 0 / Important 6 / Minor 15

Status: DONE_WITH_CONCERNS. The revision resolves both Criticals and most Importants of the first audit. Before resuming, fold in I-1 to I-4 and I-6 (each is a few lines of plan text) and reconcile the docs branch (I-5).
