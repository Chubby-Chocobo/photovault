# Release review r4: final verification (0.3.0, snapshot 98aa810)

- Scope:
  - Primary: `git diff 7141778..98aa810` (ba2081a per-group backoff and give-up, f8c7dcb loopback/picker, 8e73761 docs, c428715 tests).
  - Secondary: a sweep of `git diff v0.2.0...98aa810` for Critical issues only.
- Full suite: `swift test` in a throwaway worktree at 98aa810 ran 1195 tests in 200 suites. All passed.
- Probes:
  - They ran in a second throwaway worktree at 98aa810. Both worktrees have been removed. Nothing in the shared worktree was touched except this file.
  - The probe files are kept in `/private/tmp/claude-501/-Users-annh-workspace-photovault/c95079e8-f124-4c29-8253-08dccc3843e6/scratchpad/r4-probes/`.
  - Every probe moves the clock during a pass: each read takes 2 s (`SlowCloudSource` or a counting/flaky wrapper).
  - Harness note: `settle(rounds: 3)` adds another 180 s, so one "5-minute step" is really 8 minutes. The timings below are measured from `h.clock.now`, not from the number of steps.

## The decided model against the code

| Rule | Code | Evidence |
|---|---|---|
| 1. Each group has its own wait in memory: 30 s, doubling, at most 1 h. Groups that never failed come first, in `group_key` order. Failing groups follow, soonest `retryAt` first. | `ImportHolds.noteFailure` sets the wait to `min(30·2^(n-1), 3600)`. In `ImportStage+Ingest.swift:54-68`, `nextGroups` takes fresh groups first, leaving out every failing group, then fills the free slots with due groups sorted by `(retryAt, key)`. | `theWaitDoublesFromThirtySecondsUpToAnHour` passes. q7 (200 files, 50 stubborn): 1,600 reads over about 48 h, which is about 1 read per stubborn group per hour once the wait reaches its cap. |
| 2. A group is given up at 10 or more counted failures and at least 24 h between the first and the latest. A failure counts only in a pass where the probe answered. If the probe fails, the job goes offline and nothing is counted. | `scan` probes before every `ingestBatch` (`ImportStage.swift:139`). On `.unavailable`, `reachable` runs again before `retryLater`. There is no gap reset. | q5: a lone stubborn group is given up at 24.65 h, after 30 reads. q1: reads failed once, then the probe was down for 72 h. The files stayed pending and offline (`unavailable`). After recovery all 4 were imported and none failed. |
| 3. The breaker stops a pass after 3 fresh groups fail in a row. Groups that were already failing do not count. Failures in a tripped pass still count. | `guard isFresh else { break }`. `noteFailure` runs before the trip, then `pauseBriefly` and `break loop`. A fresh group always comes before any retry in a batch, so a retry cannot break up a run of fresh failures. | q6: the first 10 of 50 files are stubborn, batch 20. All 40 good files are imported within the first harness hour, and the 10 stubborn ones fail by 30 h, completed. |
| 4. Mac-folder imports are unchanged. | `.unavailable` on a `localFolder` still fails the file at once, and `LocalFolderSource` never throws `.busy`. | p8: `[failed 3, imported 1]`, completed. |

Round-3 regressions, re-run at 98aa810 with time moving:

| Probe | r3 at 7141778 | 98aa810 |
|---|---|---|
| p1: a and b busy, c fine | `[imported 1, pending 2]`, scanning | `[imported 1, failed 2]`, completed |
| p2: a, b, c busy at the head | `[pending 5]` | `[imported 2]` right after the start. At 30 steps: `[imported 2, failed 3]`, completed |
| p3: b, c, d busy | `[imported 1, pending 5]` | `[imported 3, failed 3]`, completed |
| p4: as p2, `.unavailable` with the probe answering | `[pending 4]` | `[imported 1, failed 3]`, completed |
| p5: a lone stubborn group, then a 3 h sleep | `[imported 1, pending 1]` | `[imported 1, failed 1]`, completed |
| p7: a, c, e busy among 8 | n/a | `[imported 5, failed 3]`, completed |
| p9: 120 files, busy at positions 5, 30 and 55, batch 20 | `[imported 74, pending 46]` | `[imported 117, pending 3]` after 1 step-hour. Later `[imported 117, failed 3]`, completed |

Other checks:

- **A download-only outage of less than a day fails nothing.** 40 files, every read `busy` while the probe answers. After 20 h and after 23 h they are `[pending 40]`. After recovery they are `[imported 40]`, completed.
  - The same outage lasting more than 24 h fails them all. This is the documented trade-off.
- **A file that fails every other read is never given up.** q4: `[imported 3]`, completed.
- **Read load during a long failure is bounded.** In probe c40, all 40 files fail and the probe answers. Reads fall from 170 per hour to between 25 and 49 per hour, which is at most one read per group per hour.
- **Probe failing:** nothing is counted (q1).
- **The 24 h window includes time when the probe was down.** q1b: the files failed once, then the probe was down for 72 h, then the probe came back while the reads still failed. They were given up 1 to 2 harness hours later. This is what the decided model says ("between first and latest counted failure"), and the ADR says so ("a gap between passes does not restart the count").
- **Round-3 Minors:**
  - Minor 1 is fixed. With `state` after more than 256 KiB of ids, the browser gets 400 with the "too many items" page, and the flow ends with `requestTooLarge` after 0.11 s. A stray request without `state` is still read only up to 1 MiB and then refused with 413. `respondSelectionTooLarge` now covers 5,377 to about 7,700 ids. The cap is 5,376, and 5,377 ids take 193,569 bytes.
  - Minor 2 is fixed. The test now expects `openURL` to be called only after the squatter leaves the port.
  - Minor 3 no longer applies: the give-up loop was removed.
- **Concurrency:**
  - `ImportHolds` state is read and written under its lock.
  - The in-memory `failing` map is cleared on sign-in (`clear`) and per group on commit (`settled`).
  - A cancelled import leaves a few entries in memory until the app relaunches. They are not used, and their size is bounded.
- **SQL:** the `NOT IN` and `IN` lists grow with the number of failing groups. The system SQLite has `SQLITE_LIMIT_VARIABLE_NUMBER` = 500000 (measured, 3.51.0), so the lists cannot hit the limit.

## Secondary sweep (v0.2.0...98aa810), Critical classes only

- **Double upload or corruption:** an export from a cloud import checks the downloaded SHA-256 against the hash recorded at import, and a mismatch gives `fileChanged` (`ExportWorker+SourceFailures.swift:23-26`).
- **Token or id leak:** the only new log lines that interpolate values are the `drive.http` debug lines, which log the method, host and `PathTemplate` path. Every other new log line is fixed text.
- **Crash:** the new force unwraps are on constant URLs and `URLComponents` built from them, plus `Unicode.Scalar` of a code unit below 0x7F. None of them can trap.
- **Stuck state:** every probe above ends `completed`, or `offline` with a reason while the provider is down.
- **No Critical issue found.**

## Critical

None.

## Important

None.

## Minor

### 1. The new outage test asserts nothing
- **Where:** `CloudImportStubbornFilesTests.anOutageWhereTheProviderDoesNotAnswerFailsNothing`.
- **Evidence:** probe q0 uses the same setup.
  - `startCloudImport` settles 6 rounds, and in that time all 3 files are imported and the job is `completed`.
  - The test sets the probe and read failures only after that. Nothing is pending during the "72 h outage", so the expectations hold whatever the code does.
- **Coverage gap:** the test it replaces, `aProviderWideOutageOfThreeDaysGivesUpNothing`, was deleted in c428715. So the rule "probe fails → nothing counted" no longer has an engine-level test.
- **The code is correct:** probe q1 shows the behaviour is right.
- **Fix:** set `source.setFailure(.inspect, SourceError.unavailable)` before `startCloudImport`, so the first reads fail and count once while the probe answers. Then fail the probe for 72 h. Expect `[pending 3]` with status `offline`, then `[imported 3]` and `completed` after recovery. This is the q1 probe.
- **Related, test wording only:** the stubborn-file tests' `run(h, hours: N)` covers about 1.6 × N hours because of `settle`'s 60 s per round. The assertions still hold, but "within the first hour" is really 1.6 h.

### 2. Doc remnants of the old model
- **ADR 0026, the first "Chosen" bullet of "One file that cannot be read now…" (line 83), still says:**
  - "skipped for a cooldown (30 s)": the wait now doubles per group.
  - "Only when nothing in a pass could be read does the whole job back off": `if waited, !progressed { pauseBriefly(id) }` was removed. The job now pauses only when the breaker trips or the probe answers `busy`.
  - The sub-bullets below that bullet are correct.
- **ADR and FR-124: "when the probe fails the job goes offline".** A `busy` probe pauses the job for 30 s without taking it offline. Nothing is counted in either case, so the rule holds; only the wording is off.
- **ADR, FR-124 and plan: "a relaunch … only delays giving up".** Because the counts are in memory, an app that relaunches more often than every 24 h never gives up a stubborn group. That import stays open until the owner cancels it. The limitation is documented. The wording "only delays" is a little optimistic.
- **`codebase-summary.md` says "196 suites in the full run".** The run gives 200. The test total, 1,195, matches.

## Unresolved questions

1. Minor 2, relaunches: is "an import with a stubborn file stays open if the app is relaunched daily" acceptable for 0.3.0? The alternative is to persist `first` and `tries` per group. Persisting them changes the schema, so it is the lead's call. It does not block the release.
2. Unchanged from r3: in which order does Google's Picker redirect put `state` and `picked_file_ids`? Both orders are now handled, so this no longer blocks anything.

Counts: Critical 0 / Important 0 / Minor 2

Status: DONE
Summary:
- At 98aa810 the code does exactly what the decided model says. The docs match it apart from one stale ADR sentence and some loose wording.
- Every round-3 regression probe (p1 to p5, p7, p9) now ends `completed`, with only the stubborn files failed. A download outage shorter than a day fails nothing, and a probe outage counts nothing.
- The full suite passes (1195 tests).
- The only findings are a test that asserts nothing and some doc remnants.
