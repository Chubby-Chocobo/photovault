# Release review r2: cloud import adapters (0.3.0)

- Snapshot: `b9c704f`. Scope: `Sources/PhotoVaultDrive`, `Sources/PhotoVaultDropbox`, `Package.swift` and their tests over `v0.2.0...b9c704f`. Focus: round-1 fixes in `21144c3..b9c704f` (63e57b5, and the sign-in cancellation in 41c8456).
- Tests: in a throwaway worktree of `b9c704f`, `swift test --filter "PhotoVaultDriveTests|PhotoVaultDropboxTests"` ran 216 tests in 38 suites. All 210 project tests passed. The only 2 failures are the probes below that were written to fail if the defect exists.
- Probes ran in throwaway worktrees of `b9c704f` and `21144c3`. Both worktrees have been removed. The shared worktree was not touched apart from this file.

## Critical

None found.

## Important

**I1. Picking 5,001 to about 7,700 items silently imports only the first 5,000.**
- Where:
  - `GooglePickerFlow.swift:111`: `parseIds` stops at `maxPickedIds = 5000` and raises no error.
  - `LoopbackRequestParser.swift:29`: the request-line cap is now 256 KiB. That holds about 7,700 Drive ids (34 bytes each).
- Probe: a real `LoopbackRedirectServer` and `GooglePickerFlow.run()` received a callback with 6,000 ids (204 KB). The flow returned 5,000 `pickedIds`, did not throw, and the browser page said "Done".
- Scenario:
  1. The owner follows the app's hint ("⌘A selects all") in a Drive folder of 6,000 photos.
  2. The import lists and finishes as normal.
  3. 1,000 photos the owner chose are never imported, and nothing says so.
  - Before 63e57b5 this could not happen, because the 8 KiB cap rejected anything over about 230 ids. Raising the cap made the silent cut reachable. `theLargestAcceptedSelectionFitsTheRequestLimit` checks only one direction of the limit.
- Caveat: I have not verified that Google's Picker lets a single pick go above 5,000 items.
- Fix: make a single limit decide.
  - Either: when `parseIds` sees more than `maxPickedIds` valid ids, throw `PickerError.selectionTooLarge`. Call `server.respond(success: false)` or show the too-large page.
  - Or: raise `maxPickedIds` to what 256 KiB carries, so the request-line cap is the only gate.
  - Add a test with `maxPickedIds + 1` ids.

## Minor

**M1. Cancelling a Dropbox sign-in and clicking again at once can report "Another app is using the Dropbox sign-in port".**
- Where:
  - `DropboxAuth.swift:68`: any failure of `start()` becomes `portInUse`.
  - `LoopbackRedirectServer.finish`: `listener.cancel()` is asynchronous, so the fixed port 53682 is not free yet when the call returns.
- Probe: 8 rounds of sign-in, cancel after 150 ms, then sign in again immediately on the same fixed port. Results: 7 × `cancelled` and 1 × `portInUse`.
- Why it matters now: 41c8456 added the cancel action in the UI, so this sequence became reachable. A second click shortly after works.
- Fix: in `signIn`, retry `start()` a few times (for example 5 × 200 ms) before reporting `portInUse`. Or let `cancel()`/`finish` await the listener's `.cancelled` state.

**M2. Any local process can end a pending sign-in or pick without knowing `state`.**
- Where: `LoopbackRedirectServer.swift:138-143`. A request that starts with `GET /oauth2/callback` and exceeds 256 KiB calls `finish(.failure(.requestTooLarge))` before `state` is checked.
- Probe: a callback with no `state` and 256 KiB + 10 bytes of padding ended `awaitCode` with `requestTooLarge`.
- This breaks the invariant in the class doc: "a callback with the wrong `state` gets a 400, neither consumes the slot". The impact is a local nuisance only. The owner sees "Too many items" and tries again. No code or token is exposed.
- Fix: end the flow only when the buffered bytes contain `state=<expected>`. Otherwise answer 400 and keep listening.

**M3. Cancelling a Dropbox sign-in during the token exchange shows a network error banner.**
- Where:
  - `DropboxAuth.swift:120-121` maps `URLError.cancelled` to `SourceError.cancelled`.
  - `AppModel+CloudImports.reportCloudFlowError` treats every `SourceError` other than `accessRevoked` as "Can't reach Dropbox. Check the network".
- Trigger: the owner presses Cancel in the second or so after consenting in the browser.
- Fix: return quietly on `SourceError.cancelled`. This is a one-line change on the app side.

**M4. (Round-1 M2, still open, now reachable) A Drive listing makes one serial `files.get` per picked id.**
- Where: `DriveImportListing.swift:89-91`.
- With I1's fix, up to 5,000 or more ids can arrive. A listing, and every relist that `resolve` triggers for an unknown path, then makes 5,000 serial requests. At 100-200 ms each that is about 8-17 minutes.
- One transient 5xx anywhere in that run discards the whole listing (`pauseBriefly`, then it starts again from the first id).
- Fix: use a bounded `TaskGroup` of about 8 requests.

## Round-1 fixes (verified)

| r1 item | Status | Evidence |
|---|---|---|
| I1: 8 KiB cap, 20-minute hang | Fixed | 2,000 ids: `.timeout` on `21144c3`, and accepted on `b9c704f` (shipped test). An oversize callback ends the flow at once. The client got the readable 400 page at 263 KiB and 600 KiB, 6/6 runs each. At 2 MiB the client sees a connection reset (unread request bytes when the server closes); the flow still ends at once and the app shows its notice. Needs about 60,000 ids, so it is not practically reachable. |
| I2: a failed relist made paths missing for 30 s | Fixed | The shipped `aRelistThatFailedDoesNot…` fails on `21144c3` (`nil`) and passes now. `lastRelist` is set only after `merge` succeeds. |
| M1: memory ahead of disk after a failed write | Fixed | The shipped `aFailedWriteIsRetried…` fails on `21144c3` and passes now. |
| M3: a new `URLSession` per download | Fixed | See "Shared streamer" below. |
| `downloadQuotaExceeded` maps to `.busy` | Correct | An inspect waits per group and is given up after 24 h. An export retries as transient without counting attempts. The quota resets, so it never becomes stuck. The reason string is matched exactly, and the existing test covers it. |
| I3: sign-out revokes imports of the same account | Accepted and documented in ADR 0026 (app scope) | n/a |
| M4: refresh tokens never deleted | Still open, not re-reported | n/a |

## Shared streamer (`URLSessionStreamer`), checked

- Routing probe:
  - Setup: one transport ran 12 concurrent 2.5 MiB streams alongside one stream whose sink throws and one stream that gets a 500. The run was repeated for 5 rounds.
  - Every SHA-256 matched its own source.
  - The router's route table was empty afterwards.
- Cancellation probe: 20 mid-body cancels plus one task cancelled before it started all threw `CancellationError` and left the route table empty.
- Code reading:
  - Task ids are unique: there is one session per streamer and it is never re-created.
  - Registration happens before `resume()`, so no event can arrive unrouted.
  - The delegate queue is serial (`delegateQueue: nil`), so the order of chunks is kept.
  - The continuation is finished exactly once, in `didCompleteWithError`.
  - `onTermination` unregisters and cancels, which breaks the continuation→router→route cycle on every path.
  - A late callback for an unregistered task gets `.cancel` or is dropped.
  - Backpressure is per `Flow`, unchanged.
  - Partial files are aborted by the callers on every throw (`DriveImportSource.download`, `DropboxClient.download`).
  - The session is invalidated in `deinit`. `stream` holds `self` while it runs, so invalidation cannot happen mid-download.
- Drive destination: no regression. Uploads and sign-in use `URLSessionTransport.send` with the unchanged plain `session`, and the destination never streams. The new 256 KiB loopback cap is harmless for sign-in callbacks.

## Loopback server, checked

- The listener is still bound to `127.0.0.1` only (`requiredLocalEndpoint`).
- Memory per connection is at most 256 KiB + 16 KiB.
- Each connection is still cancelled after `connectionTimeout` (10 s), so a slowloris sender is cut off.
- Re-decoding the buffer on every chunk is quadratic in theory, but it is bounded by the cap and the 10 s timeout.
- Pages echo nothing from the request.

## Sign-in cancellation, checked

- `awaitCode` already had `withTaskCancellationHandler`, which existed since 0.1.0. 41c8456 adds the app's cancel action and tests. Both new tests pass.
- Cancelling before or during the wait ends the wait at once and closes the listener (M1 is about how fast the port is released afterwards).
- Cancelling after the code arrives runs `respond(success: false)`.

## Token leakage, checked

No change in this round. The new error page and `selectionTooLarge` carry no request data, and `LoggingHTTPTransport` is unchanged.

## Unresolved questions

1. I1: does Google's desktop Picker allow more than 5,000 items in one pick? If it caps lower, I1 drops to Minor, but an explicit error is still the safer contract.
2. Will Google's 302 actually carry a `Location` of about 170 KB? Only the owner's E2E run with a large pick can confirm that.

Counts: Critical 0 / Important 1 / Minor 4

Status: DONE_WITH_CONCERNS
Summary: The round-1 adapter fixes are real (all three tests fail on 21144c3 and pass now), and the shared streamer routes, cleans up and cancels correctly under concurrency. One new Important: with the larger callback cap, picks of 5,001 to about 7,700 items are silently cut to 5,000.
