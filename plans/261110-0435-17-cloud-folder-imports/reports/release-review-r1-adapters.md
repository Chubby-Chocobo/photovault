# Release review r1: cloud import adapters (0.3.0)

- Snapshot: `21144c3`, diff `v0.2.0...21144c3`, limited to `Sources/PhotoVaultDrive`, `Sources/PhotoVaultDropbox`, `Package.swift` and their tests.
- Tests: in a throwaway worktree of `21144c3`, `swift test --scratch-path .build-r1a --filter "PhotoVaultDriveTests|PhotoVaultDropboxTests"` ran 201 tests in 34 suites, and all passed.
- Empirical probes, in the same throwaway worktree and since removed:
  - The real `LoopbackRedirectServer` was sent picker callbacks with 200, 240 and 300 Drive-style ids.
  - The fixed redirect port was reused three times in a row.

## Critical

None found.

## Important

**I1. Picking more than about 230 items on Google Drive fails. The browser gets a blank 400 and the app waits 20 minutes.**
- Where:
  - `LoopbackRequestParser.swift:25` sets `maxRequestBytes = 8192`.
  - `LoopbackRedirectServer.swift:130-140` answers 400 once 8 KiB has arrived without a CRLF.
  - `GooglePickerFlow.swift:29` sets `maxPickedIds = 5000` and `:31` sets `pickTimeout = 20 min`.
- Probe results. The probe used 33-character ids, as Drive issues them, plus a code and the scope:
  - 200 ids (about 6.9 KB): accepted.
  - 240 ids (about 8.3 KB): browser 400, `awaitCode` → `.timeout`.
  - 300 ids: browser 400, `awaitCode` → `.timeout`.
- Scenario:
  1. The owner follows the app's own hint (`CloudImportText.emptyGoogleHint`: "select the photos inside the folder (⌘A selects all)") on a folder of 500 photos.
  2. Google redirects with roughly 17 KB of `picked_file_ids`.
  3. The server answers `400` with an empty body. The browser shows a blank page.
  4. The callback is never accepted, so `run()` hangs until the 20-minute timeout.
  5. Meanwhile `cloudFlowBusy` blocks every other cloud flow, including Dropbox sign-in and reconnect, and nothing in the UI can cancel it.
  6. The owner then sees "timed out" and the selection is lost. Retrying the same selection fails the same way.
- Why it matters: a folder-only pick often yields nothing under `drive.file` (ADR 0026, and the hint exists for this reason). For any folder of more than about 230 photos, the only working path is picking in batches of 200 or fewer and reconnecting again and again.
- `maxPickedIds = 5000` shows the intent was about 170 KB of ids, so the two limits contradict each other.
- Fix:
  - Raise the request-line limit for the callback to at least `maxPickedIds × 35` plus headroom, for example 256 KiB. This is a loopback-only listener, so the DoS cost is nil.
  - Keep the 8 KiB limit only for header bytes after the request line, if wanted.
  - Make the oversize path finish the flow with a distinct error, for example `PickerError.tooManyPicked`, with a page that says so, instead of silently waiting for the timeout.
  - Add a server test with 1,000 ids.

**I2. A failed relist turns every unknown path into a permanent `fileMissing` for 30 s.**
- Where: `RemoteIdIndex.swift:72` and `:85-88`. The `defer` sets `lastRelist = .now` even when `relist` throws. `DriveImportSource.swift:84` and `DropboxImportSource.swift:69` then throw `.fileMissing` for a nil answer.
- Scenario:
  1. A path is not in the map. The JSON is missing or corrupt, which starts an empty map. Or a `persist` failed earlier (see M1).
  2. Export A triggers the relist, and the relist fails because the Mac just woke offline, or on a 429 or 5xx. A correctly gets `.unavailable` or `.busy`.
  3. Export or inspect B arrives within 30 s. It finds `relisting == nil` and a fresh `lastRelist`, gets `nil`, and throws `SourceError.fileMissing`.
  4. The engine records that item as missing for good. A transient network fault becomes a lost photo.
- Fix: set `lastRelist` only after `merge` succeeds, for example by moving it out of the `defer` into the success path. Add a test where the first relist throws and a second caller within the interval still gets a retryable error or a fresh relist.

**I3. Signing out of the Google destination (or changing its account) can revoke every Drive import grant of the same account.**
- Where:
  - `CloudImportServices.swift:57-66` and `AppEnvironment.swift:136/165`: the imports use the same OAuth client ID as the destination.
  - `AppModel+Account.swift:48-55`: `signOutGoogle` revokes the destination token.
- Scenario:
  1. The owner backs up to Drive with account A and starts a Drive import from A.
  2. They sign out of Google, or switch the destination account, while the import is open or still has pending exports.
  3. Google revokes the whole grant for that client and user, and probably the project: RFC 7009 §2.1, and Google's answer in the developer forum (see sources).
  4. The next import refresh gets `invalid_grant`, then `accessRevoked`, and the job is held for sign-in. For a finished import, pending exports follow the revoked-grant path (earlier review, I8).
- Workaround: "Đăng nhập lại" on the import.
- Fix: verify with a manual test (revoke the destination token, then refresh an import token). If it is confirmed:
  - Warn before sign-out when Drive imports of that account are open.
  - Or skip revoking at sign-out while such imports exist.
  - Or document the coupling in ADR 0026.

## Minor

**M1. A failed map write leaves memory ahead of disk, and it is never written again.**
- Where: `RemoteIdIndex.swift:51-65`. `ids` and `pathById` are mutated before `persist()`. A later merge with the same listing has `changed == false` and skips the write.
- Scenario:
  1. The disk is full, so the first `stabilize` throws `readFailed`.
  2. The next cycle's listing succeeds without writing the file.
  3. After a relaunch the map is rebuilt from a new listing. Paths of files renamed in between move, which feeds I2 and the I4 drift that the index was built to stop.
- Fix: persist a copy first and swap it in only on success, or track a `dirty` flag.

**M2. A Drive listing makes one sequential `files.get` per picked id.**
- Where: `DriveImportListing.swift:89-91`.
- Cost: once I1 is fixed and 2,000 photos can be picked, every `listFiles`, and every relist from `resolve`, makes 2,000 serial requests, several minutes per listing.
- Fix: run them in a bounded `TaskGroup` of about 8, or skip `get` for ids already in the map.

**M3. A new `URLSession` for every download.**
- Where: `URLSessionStreamer.swift:20`.
- Cost: every cloud file is downloaded twice (inspect and export), each over a fresh TLS connection with no connection reuse. That adds about 100-300 ms per file on large imports.
- Fix: one long-lived session with a delegate that routes by task id.

**M4. Import refresh tokens are never deleted or revoked.**
- Where: `DriveImportAuth.removeGrant` has callers only on a failed start. There is no call when an import is removed or finished.
- Scenario: Google keeps 100 refresh tokens per account per client ID and silently invalidates the oldest. After about 100 picks or reconnects with the destination account, the oldest token is invalidated, and that is typically the destination's own sign-in. Drive backup then stops with "sign in again".
- Fix: delete, and optionally revoke, the `import-<id>` grant once an import is closed and has no pending exports, or when it is removed.

## Fixes from the earlier review (verified, not re-reported)

| Item | Status |
|---|---|
| I2 (cancellation returns a short body) | Fixed. `URLSessionStreamer` has the `.completed` event and `checkCancellation`. |
| I3 (a non-`SourceError` escapes) | Fixed. Both adapters' `map` defaults to `.unavailable` and the Drive scratch dir is wrapped. |
| I4 (duplicate-name drift) | Fixed by `RemoteIdIndex`, apart from the I2 and M1 gaps above. |
| I7 (Factory Reset leaves grants) | `KeychainStore.accounts()` and the `isCloudItem` filter are in place. The destination item is not matched. |
| I9 (two streamers) | Fixed. There is one delegate streamer, behind `LoggingHTTPTransport`. |
| M1 (a 403 on a pick holds the job) | Fixed (`isPerItem`). |
| M2 (concurrent exports each list) | Fixed with a single-flight relist. |
| M3 (Dropbox folder casing) | Fixed. |
| M4 (Dropbox root rename) | Fixed (probe on `fileMissing`). |
| M5 (Dropbox token errors map to revoked) | Fixed. |
| M6 (picked ids replaced) | Fixed. |
| M7 (picker timeout) | Fixed (20 min). |

## Checked, no issue

- PKCE S256 and random state with constant-time compare on both flows. A stray request with the wrong state does not consume the slot.
- No token appears in logs, `description` or error reasons. Dropbox headers and the token body are never logged, and the path template masks ids.
- Keychain items are data-protection, this-device-only. `listQuery` returns attributes only.
- Streaming:
  - Backpressure is bounded at about 8 MiB.
  - A sink error, cancellation, a non-2xx answer and a 401 retry all leave no partial file.
  - The continuation is finished exactly once, by the delegate.
- Dropbox:
  - The `Dropbox-API-Arg` escaping is correct for non-ASCII and DEL.
  - Cursor paging is followed and downloads go by id.
  - `Retry-After` is honoured once, up to 30 s.
  - The fixed port 53682 can be reused right after a sign-in (probed three times in a row).
- The Drive destination paths touched in this release show no regression:
  - `URLSessionTransport` builds the same configuration.
  - `KeychainStore` defaults to the same service.
  - The loopback server's `port: 0` is unchanged for sign-in.

## Unresolved questions

1. I3 rests on Google revoking at the grant or project level, not per token. Can the owner confirm it with one manual revoke test?
2. The Picker desktop docs say the redirect URI must be public HTTPS. ADR 0026 already lists the loopback as unverified until the owner's E2E run. Has that run happened?

Sources: [RFC 7009](https://www.rfc-editor.org/rfc/rfc7009), [Google dev forum: clients revoking each other's tokens](https://discuss.google.dev/t/multiple-oauth-clients-in-the-same-google-cloud-project-revoking-each-others-token/293608), [Google Picker for desktop apps](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker?hl=en)
