# Release review r3: verification of the round-2 fixes (0.3.0, snapshot 7141778)

- Scope: `git diff b9c704f..7141778` (3d68818, c941bf2, 0d3d8fa, d590224, f43d7bb), plus the code those commits call.
- Full suite: `swift test` in a throwaway worktree at 7141778 ran 1185 tests in 199 suites, and all passed.
- Probes:
  - The same probe files ran in throwaway worktrees at 7141778 and at b9c704f. The 7141778 `CloudImportTestKit.swift` was copied into the b9c704f worktree.
  - Both worktrees have been removed. The shared worktree was not touched apart from this file.
  - The probe files are kept in `/private/tmp/claude-501/-Users-annh-workspace-photovault/c95079e8-f124-4c29-8253-08dccc3843e6/scratchpad/r3-probes/`.
  - They step the clock in 5-minute steps, which matches the new recheck. `ZZSlowSource` moves the clock forward by 2 s on every read, because a real pass takes time.

## Round-2 findings: status

| R2 | Status | Evidence |
|---|---|---|
| Engine I1: two short failures a day apart fail a file | Fixed | The gap of more than 2 h and the 10-try minimum both apply (`ImportHolds.noteFailure`). The shipped `twoShortRefusalsMoreThanADayApart…` test passes. |
| Engine m2: a pair takes about n × 24 h | Fixed | The streak is now kept per group and is cleared only when the group is settled. `aPairOfFilesIsGivenUpTogether…` passes at 28 h. |
| Engine m3: a revoked import asks the provider up to 200 times an hour | Fixed | `signInDeferred` skips that source's queued candidates. The new test counts adapter calls (≤ `maxConcurrentExports`). The set is keyed by `asset.sourceId` and reset in each `runPass`, so other sources and Photos are not skipped and nothing is held past the pass. The release on sign-in is unchanged (`releaseExports`). |
| Engine m4: provider-wide trouble is handled one file at a time | Fixed, but it causes the regressions below | There is a breaker after 3 groups in a row, and the give-up is decided once at the end of the pass. |
| Engine m5: a retry waits for the hourly timer | Fixed | `needsAvailabilityRecheck` now also returns true while a cloud import is `scanning` (every 5 min). |
| Engine m6: an assertion that proves nothing | Fixed | Removed. `ImportHoldsTests` covers the streak directly. |
| Adapters I1: a large pick is silently cut to 5,000 | Fixed | `maxPickedIds` is now 5376. Probe: 5,377 ids throw `selectionTooLarge` and 5,376 parse; 5,377 ids take 193,569 bytes, under 256 KiB. |
| Adapters m1: Dropbox port busy right after a cancel | Fixed | `listen` retries with a new listener for 2 s, and a cancel during the wait becomes `.cancelled`. See Minor 3 on the test. |
| Adapters m2: a stray oversized request ends the flow | Fixed, with a caveat | `carriesState` is checked. See Minor 2. |
| Adapters m3: Dropbox cancel shows a network error | Fixed | `SourceError.cancelled` is now quiet, and `trackedFlow` is quiet once the task is cancelled. |
| Adapters m4: picked ids are read one after another | Fixed | `pickedItems` runs at most 8 at a time and sorts the results back into `pickedIds` order. Root order, and so `ImportNames.assign` collision suffixes and relative paths, does not depend on which answer comes first. `walk` is unchanged. A throttling 403 maps to `rateLimited` and is retried; only 404 and access-403 drop an item, as before. |
| App I1: README says throttling never fails a file | Fixed | The bullet was removed and merged into the give-up bullet. |
| App m1: Huỷ after the browser step | Fixed | `checkCancellation` is called before the Keychain write and before `startImport`. On every throw the Google grant and the Dropbox `import-<id>` copy are removed. `startImport` writes the row in one GRDB transaction, so a cancel leaves either a full import or nothing: no orphan token and no orphan import. The sheet cancels `startTask` in `onDisappear`. |
| App m2: every Dropbox error is silent | Fixed | Only `access_denied` is quiet. Other errors become `.failed` and show a notice. Google is changed the same way. |
| App m3: the email is the identity | Accepted | Recorded in ADR 0026 and the plan. |
| App m4: disk-wait text | Fixed | Now "file" and "ổ Mac". The menu card shows it. |
| App m6: Google token limit wording | Fixed | README and ADR. |
| App m7: uninstall leaves Keychain tokens | Fixed | privacy.html. |
| App m8: factory reset during a sign-in | Fixed | `cancelCloudFlow()` is called first. |
| App m9: Dropbox sheet loads overlap | Fixed | A generation guard drops answers for a folder the owner has left. |

Mac-folder imports are unaffected. A `LocalFolderSource` never throws `.busy`, and its `.unavailable` while the folder answers still fails the file at once. Probe p8, three unreadable files at the head of a Mac folder, gives `[failed 3, imported 1]`, completed. The breaker and streaks are reached only through `.waitingForProvider`, which a Mac folder never returns.

## Critical

None found.

## Important

### I1. Three files that keep failing stop the rest of a cloud import from being read; the import never finishes and says nothing
- **Where:** `ImportStage+Ingest.swift:36-47` and `ImportHolds.swift:58`.
  - `nextGroups` orders by `group_key`.
  - A group that failed is blocked for only 30 s (`backoff`).
  - The breaker then pauses the job for 30 s, timed from the end of the pass.
- **Mechanism:**
  1. Once their 30 s blocks have expired, the stubborn groups are again the first pending groups, so every later pass tries them first.
  2. Three of them in a row trip the breaker before any other group is reached. The pass returns, and `giveUpStubbornGroups` is never called.
  3. Nothing counts toward the give-up, so the import never progresses and never ends.
  4. The row stays `scanning` with no reason, and the 5-minute recheck repeats this forever.
- **Evidence:** the same probes on both snapshots; counts after 30 h.

| Probe | 7141778 | b9c704f |
|---|---|---|
| p2: a, b, c always busy; d, e fine | `[pending 5]`, scanning | `[imported 2, failed 3]`, completed |
| p3: b, c, d busy; a, e, f fine | `[imported 1, pending 5]` | `[imported 3, failed 3]`, completed |
| p4: as p2, with `.unavailable` (the probe answers) | `[pending 4]` | `[imported 1, failed 3]`, completed |
| **p9: 120 files, busy files at positions 5, 30 and 55, batch of 20, 2 s per read** | **`[imported 74, pending 46]`**: 43 good files are never read | `[imported 117, failed 3]`, completed |

  - p9 is the realistic case. The three files do not need to be next to each other: they become the head of the queue once the passes have moved past them.
- **Trigger:**
  - Any cloud import larger than about one pass, with 3 or more files that keep returning `busy` or `unavailable`.
  - Drive `downloadQuotaExceeded` (mapped to `.busy`) clears within about a day, so a stall caused by it ends by itself.
  - A file that keeps returning 5xx, or keeps stalling, stalls the import for good.
- **Workaround:**
  - Cancel the import.
  - Importing the same selection again stalls at the same place. Picking smaller sets is the only way to get the rest.
- **Regression:** at b9c704f every one of these imports finished.
- **Fix (suggested; the lead decides):**
  - (a) A group that already has a streak is known to be stubborn. Do not count it toward `troubled`, and let the pass go on to fresh groups. Count only fresh groups toward the breaker.
  - (b) When the breaker trips, block the tripped groups for longer than the job pause, for example the 5-minute recheck. The next pass then starts past them, so a run of stubborn files at the very start (p2) also lets the rest be read.
  - Add p3 and p9 as tests.

### I2. Two or more files that keep failing at the end of an import are never given up, so the import never finishes
- **Where:** `giveUpStubbornGroups`, `guard readSomething || failed.count < 2 else { return }`.
  - Once only stubborn groups are left, a pass reads nothing and fails 2 or more groups.
  - That counts as a provider-wide outage, so the streaks started earlier never reach their limits.
- **Evidence:**
  - p1 (a and b always busy, c fine) gives `[imported 1, pending 2]`, scanning, after 30 h and again after a further 72 h. b9c704f gives `[imported 1, failed 2]`, completed.
  - The shipped tests cover exactly one stubborn group (`oneBadFileAmongReadableOnesIsStillGivenUp`, and the pair test).
- **Impact:**
  - The give-up rule now works only when exactly one stubborn group is left, or when the import still has readable work 24 h after the failures began.
  - ADR 0026 lists only "an import whose only unreadable group fails from the very first pass" as the case that stays open. README, FR-124 and the plan all say a stubborn group "is given up … so the import can finish". With 2 or more stubborn files, that is false.
  - A cycle runs every 5 min for as long as the row stays open.
- **Related (same root cause):**
  - p5: a lone stubborn group whose streak began while other files were being read, followed by a 3 h sleep.
  - The gap resets the streak, and `startsStreak: false` then drops it for good, so the import never finishes (`[imported 1, pending 1]` after 48 h; b9c704f gives failed 1, completed).
  - The ADR says a gap makes the clock "start again", not stop.
- **Workaround:** cancel the import.
- **Fix (suggested; this changes the decided semantics, so it is the lead's call):**
  - When a pass has no fresh failures (every failed group already has a streak), let it continue those streaks whatever the count. When the gap resets a group that already has a streak, restart it instead of dropping it.
  - A provider-wide outage still never starts a streak, because fresh groups fail too. The remaining risk: a group that was already failing before an outage can be given up during the outage. Its file was failing on its own anyway.
  - Add p1 and p5 as tests.

## Minor

### 1. An oversized pick whose `state` comes after the ids leaves the flow waiting until the 20-minute timeout
- **Where:** `LoopbackRedirectServer.swift:139-148` with `LoopbackRequestParser.carriesState`. Only the first 256 KiB or so of the request is buffered.
- **Evidence:** a probe callback `?picked_file_ids=<256 KiB+>&code=c&state=st` was treated as stray. The browser got 413 with the failure page, and `awaitCode` ended only at its timeout (8 s in the probe; `pickTimeout` = 20 min in the app). With `state` first, the shipped test shows that the flow ends at once.
- **Trigger:** more than about 7,700 picked ids, and only if Google places `state` after `picked_file_ids`. Google's guide lists `picked_file_ids` first among the appended parameters; the real order is unverified. The owner can press Huỷ.
- **Fix:**
  - Treat a `GET /oauth2/callback` whose buffered part has `picked_file_ids=` and no `state=` yet as the owner's selection too. A stray caller cannot know the path, and the impact is only ending one wait.
  - Or read until the request line ends, within a larger hard cap, before deciding.
- **Related:** when 5,377 to about 7,700 ids arrive, `selectionTooLarge` is thrown after `awaitCode`. The browser then shows the generic failure page ("sign-in failed") while the app says "too many items". Send `tooLargePage` in that case.

### 2. `aPortThatIsFreedAMomentLaterIsStillUsed` does not prove that the port was used
The test cancels at 1.0 s and expects `.cancelled`. If `listen` were still retrying, the cancelled `Task.sleep` also gives `.cancelled`, so the test only shows that no `portInUse` came within 1 s.
- **Fix:** record the `openURL` call, which happens only after the listener started, and expect it before cancelling.

### 3. Give-up passes keep going after a `.stop`
`giveUpStubbornGroups` ignores `process`'s result. If a re-read hits `.unavailable` and the probe fails, or hits `accessRevoked`, the loop still re-reads the remaining groups due for give-up. Each then probes, or calls `holdForSignIn`, again. This is bounded by the number of groups due in that pass and does no harm to the data.
- **Fix:** break the loop on `.stop`.

## Checked, no finding

- **Can a good file be failed?** The give-up re-reads the group (`process(giveUp: true)`). A read that succeeds then is imported and settled, and only a read that fails is marked `read`. The 24 h, 10-try and 2 h gap limits apply per group. A file that fails half the time is retried every pass, so it never reaches a streak of 10 or more failures over 24 h.
- **Provider-wide outage:** `aProviderWideOutageOfThreeDaysGivesUpNothing` passes for 2 files and for 5 files. Breaker passes and no-read passes with 2 or more failures count nothing.
- **Disk wait:** `waitingForDisk` neither trips the breaker nor counts toward the give-up. It is unchanged from round 2.
- **Breaker vs Photos:**
  - A trip calls `pauseBriefly` and returns. The next round skips the job without a probe, so Photos export and upload are delayed by at most 3 group reads.
  - Each 5-minute recheck runs a `.timer` cycle. That cycle already runs every 5 min for an unavailable Mac-folder destination (`backupIfDue` only when due).
- **Concurrency:** `signInDeferred` is actor state on `ExportWorker`. It is written in `classifyFolderFailure`, which is isolated to the actor. `ImportHolds.failing` is accessed under the lock.
- **Docs:** the ADR (lines 84-85), plan, FR-124, README and codebase-summary all state the same rule: 24 h and 10 tries, a 2 h gap, per group, outage never counts, the breaker of 3, and the 5-minute recheck. The only gap is the one in I2: the "never finishes" cases beyond the documented one. privacy.html matches the Keychain behaviour.
- **Privacy:** the new log lines are fixed text. The new Dropbox `.failed` notice carries no data.

## Unresolved questions

1. I1 and I2: should failures of a group that already has a streak count, and stay out of the breaker, in a pass that reads nothing? This weakens "a provider-wide outage never marks files failed" to "never marks a file failed that was not already failing on its own".
2. Minor 1: in which order does Google's Picker redirect put `state` and `picked_file_ids`? Only the owner's E2E run can show it.

Counts: Critical 0 / Important 2 / Minor 3

Status: DONE_WITH_CONCERNS
Summary: Every round-2 finding is fixed, and the full suite passes (1185 tests). The new give-up and breaker logic has two regressions against b9c704f: three stubborn files stop the rest of a cloud import from being read (p9: 43 of 117 good files are never read), and two or more stubborn files left at the end are never given up. In both cases the import stays open with no reason shown.
