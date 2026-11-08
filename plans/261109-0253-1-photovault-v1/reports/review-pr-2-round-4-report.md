# Review: PR #2 round-4 fixes (`9edb912..HEAD`)

Scope: 1af95e5 (engine), fe94c14 (local), 532b1ed (app), 2b452a1 (docs), checked against `review-pr-2-round-3-report.md`. No code changed.

Checks run:
- `swift test --scratch-path .build-main --filter "AccountChange|Recovery|LocalRootState|Integrity|ExclusiveLane|DestinationHealth"`: 114 tests in 21 suites passed.
- `xcodebuild -scheme PhotoVault CODE_SIGNING_ALLOWED=NO build`: BUILD SUCCEEDED.
- A scratch script ran `shareIdentity` on IPv6, port, percent-encoded and domain-user URLs.

## Round-3 items

| # | Status | Evidence |
|---|--------|----------|
| R1 live root inside the commit | fixed on the success path; regression N1 | `AppModel+Account.swift:163-173`. The root is set before `install`, still in the lane, and restored on a commit failure. |
| R2 watchdog signature | fixed | `AppModel+FirstStart.swift:114-118`. `ScanProgress` includes `AssetRepository.count`, which grows with each batch because the scanner resumes after the cursor (`Scanner.swift:26-31`). |
| R3 mismatch / missing | fixed | `HardeningServices.swift:53` counts every `missingRemote` job. The fold is in `EngineHardeningCommands.swift:85-107`, clamped with `min`. Notifications are split in `AppModel+Notifications.swift:18-20`. Tests are updated. |
| S-a share identity | fixed | `RootState.swift:30-45`, plus a test. IPv6 works: `smb://[fe80::1%25en0]/p` gives `smb://[fe80::1%en0]/p`, the same on both sides. Small leftovers in N4. |
| S-b two-stage marker | partly | The marker stages are correct (`AppModel+Account.swift:129-139, :163-188`). But the `signedOut` status they rely on does not hold (N1, N2). |

Deadlock check: there is none.
- The `commitAccount` closure is `@Sendable` and nonisolated. It hops to the MainActor for `setAccountChangePauseMarker`.
- The MainActor is suspended at `await env.coordinator.changeDriveAccount` (`:157`), not blocked, so the hop goes through.
- No DB transaction is held across `commit()` (`RecoveryTriggers.swift:84-86`).

## Findings

### Important

**N1. After the commit succeeds and `apply` fails, Drive goes back to `.active` with account B's token and B's root, while the database still describes account A.**
- Where: `AppModel+Account.swift:164-165` (the live root becomes B's before the commit), `:182-188` (the failure branch re-registers Drive and marks it `signedOut`), `DestinationHealth.swift:14`, `GoogleDriveDestination.swift:52-56`.
- Why `signedOut` does not hold: `DestinationHealth` only skips `userPaused`, `recovering` and `folderTrashed`. `signedOut` is overwritten by whatever `checkAvailability` returns.
- Scenario:
  1. `commitAccountChange(B)` succeeds.
  2. The `apply` store write throws (disk full, I/O error).
  3. Drive is re-registered and marked `signedOut`.
  4. The next cycle (timer, Photos change or followUp) calls `checkRoot(B's root)` with B's token, gets `.ok`, and sets Drive to `.active`.
  5. Uploads then run against A's jobs, A's folder ids and A's `driveRootId`, with `accountId` still A.
- Before this commit the same path gave B's token plus A's root, a 404, and `rootMissing`. That was a false alarm, but no uploads ran.
- Also in the same session: if the owner then signs in with A again, the same-account path (`:85-95`) commits A's token while the live root stays B's. That is a 404 and a false `rootMissing` for a root that exists.
- Fix:
  - Add `.paused(.signedOut)` to the skip list in `DestinationHealth.swift:14`. It is an owner-waiting state, and `resumeDriveAfterSignIn` already sets `.active` explicitly.
  - Also, in the committed branch, restore the live root to the database value. Alternatively, do not re-register Drive until the next sign-in.

**N2. The launch `.committing` path has the same hole, so S-b only half works.**
- Where: `AppModel+Account.swift:136-137`, `AppModel.swift:115` (`goLive` runs a cycle next), `AppEnvironment.swift:118-120` (the live root is read from the database, so it is A's).
- Scenario: the app quits after `install(B)` and before `apply`.
  1. At launch Drive is marked `signedOut`.
  2. The first cycle checks A's root with B's token, gets a 404, and sets `rootMissing`. This is the round-3 false alarm again.
  3. From there, "Upload lại vào thư mục mới" fills B while `accountId` says A.
- Fix: the same `DestinationHealth` change as N1 covers this. Add a test where `signedOut` survives a cycle.

### Suggestion

**N3. A commit failure writes a `.paused` marker even when this change never paused Drive.**
- Where: `AppModel+Account.swift:170`.
- Scenario:
  1. Drive was already paused by the owner (`wasActive == false`, so no marker was set at `:64`).
  2. The commit fails and the marker becomes `.paused`.
  3. The app quits before `cancelAccountChange` clears it (milliseconds).
  4. At launch (`:133-134`) the owner's own pause is lifted.
- Fix: restore `change.resumeDrive ? .paused : nil`.

**N4. `shareIdentity` drops the port and compares the share path exactly.**
- Where: `RootState.swift:39-45`.
- Port: `smb://nas:445/photo` and `smb://nas:10445/photo` (another server behind a tunnel) come out equal, so a false `rootMissing` is possible. This is rare.
- Share name: SMB share names are case-insensitive, and percent-escapes can differ in case. `smb://nas/Photo` against `smb://nas/photo` gives `.offline` forever. That is the safe direction.
- Fix: keep `components.port`. Lower-case the path for `smb`/`afp` only.

**N5. No tests cover the new app-side branches.**
- Untested:
  - The root swap and restore in the commit closure.
  - The committed-failure branch.
  - The launch `.committing` path.
  - The marker left as `.committing` after a successful change. If the `:176` write fails, the next launch marks Drive `signedOut`. Health then flips it back to `.active`, because both the database and the Keychain hold B. Harmless today, but only because of N1's root cause.
  - `ScanProgress`.
- An engine test for N1/N2 is possible today: `DestinationHealth` with a `signedOut` record and a checker that returns `.ok`.

## Verdict

Important findings remain: N1 and N2. They have one root cause: the `signedOut` status is not protected by `DestinationHealth`. No Critical findings.

## Unresolved questions
- Is `DestinationHealth` meant to clear `signedOut` on its own when a token works (for example after a Keychain repair)? If so, N1 needs the alternative fix: restore the live root and do not re-register Drive.
- For a mismatched file, the confirm text says "ghi lại đúng chỗ và đúng tên cũ" and the card says "File lệch không bị ghi đè". Both can only be true if the re-upload lands beside the old file under the same name (Drive) or under a suffixed name (Local, `RENAME_EXCL`). Not verified. The copy may need a clause about this.
