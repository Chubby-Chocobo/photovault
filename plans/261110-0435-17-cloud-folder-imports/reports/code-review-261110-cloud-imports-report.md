# Code review: cloud folder imports (issue #17, round 2)

- Range: `945efad...1c9d99f` (HEAD when the review started). `6678eb5` (missing-token hold, Dropbox re-register, shared key names, Google re-pick hint) landed during the review. I read it, but this report does not re-review it.
- Tests:
  - A clean `git archive` of `1c9d99f`: `swift test` ran 1101 tests in 188 suites and all passed.
  - The live worktree, with uncommitted edits in flight (`swift test --scratch-path .build-review`): 1102 tests, 1 failure, `anOpenCloudImportWithoutAnAdapterAsksForSignInAndResumesOnceOneIsAdded` (CloudImportTests.swift:148). That test belongs to the lead's edit in progress.
- Empirical probe: in Swift 6, cancelling the consuming task makes `for try await` over an `AsyncThrowingStream` end normally, with no throw (`onTermination: cancelled`, "loop ended normally"). Finding I2 depends on this.

## Critical

None found.

## Important

**I1. A transient 429/5xx while reading one cloud file fails that file for good.**
- Where: `Sources/PhotoVaultEngine/ImportStage+Ingest.swift:38-42`, with `DriveImportSource.swift:123` and `DropboxClient.swift:176`.
- Scenario:
  1. Drive or Dropbox throttles one download (429, 5xx, or a `Retry-After` over 30 s). The adapter maps it to `.unavailable`.
  2. `reachable()` probes, and the probe succeeds because the throttle has passed.
  3. The item is marked `failed "read"`. Nothing retries import items, so the photo is never imported and the job ends with "N lỗi".
- Why it is new: for Mac folders this path is rare. For cloud imports it is routine.
- Fix: when the probe succeeds after `.unavailable`, leave the item `pending`, `holds.mark` the job and return `false`. Count attempts, for example in `reason`, and fail only after N tries. Or add `SourceError.throttled` and map it the same way.

**I2. Dropbox streamer: a cancelled task returns a truncated file as success.**
- Where: `Sources/PhotoVaultDropbox/DropboxByteStreaming.swift:45-55`.
- Scenario:
  1. The task is cancelled (pause, shutdown, or an owner command) after `.head(200)` arrived.
  2. The `for try await` loop ends normally, `head` is 200, and `DropboxClient.download` calls `writer.finish()`.
  3. `inspect` returns a SHA-256 of a partial file, or `exportResource` returns a partial file.
- Today the GRDB 7 async `write` throws `CancellationError` in a cancelled task, so the bad hash and the `fileChanged` → permanent `resourceMissing` are not committed. Correctness depends on that side effect.
- Fix: yield an explicit `.completed` event from `didCompleteWithError` and throw `CancellationError` when the loop ends without it, or call `try Task.checkCancellation()` after the loop. Add a test that cancels a real streamer mid-body.

**I3. A non-`SourceError` from the Dropbox adapter aborts every sync cycle, including Photos backups.**
- Where: `DropboxClient.swift:193` (`return error` passes unknown errors through) and `DropboxAuth.swift:126`. `DropboxAuthError.malformedResponse` from the token refresh escapes `probe`, `listFiles` and `inspect` this way.
- Why it stalls everything:
  - `ImportStage.reachable` and `list` catch only `is SourceError`, and `process` catches only `as SourceError`.
  - A thrown error therefore leaves `ImportStage.run`, and `SyncCoordinator+Cycle.swift:216` aborts the cycle.
  - This repeats every cycle while the condition lasts.
- Same class on Drive: `DriveImportSource.swift:62` lets a `createDirectory` `CocoaError` escape.
- Fix:
  - Make the `mapThrown` default `SourceError.unavailable`.
  - Map `malformedResponse` to `.unavailable` inside `refresh`, but keep it for interactive sign-in.
  - Wrap the Drive scratch `createDirectory` as Dropbox already does.

**I4. Drive duplicate-name suffixes depend on sibling ids, so they change after a relist.**
- Where: `DriveImportListing.swift:39-55` and `DriveImportSource.swift:80-86`.
- How names are given: `assign` sorts by id, and the lowest id keeps the plain name. After a relaunch, `resolve` rebuilds the map from a fresh listing.
- Scenario:
  1. A folder holds `IMG_1.jpg` A and B, so the paths are `IMG_1.jpg`→A and `IMG_1 (2).jpg`→B.
  2. Before the relaunch a new `IMG_1.jpg` C with a smaller id is added.
  3. After the relaunch, the pending item `IMG_1.jpg` resolves to C, and `IMG_1 (2).jpg` resolves to A, which is counted as a duplicate.
  4. B is never read, and the import reports it as a duplicate. This is a silent loss.
- On closed imports the SHA check turns the same drift into a permanent `fileChanged` skip.
- Fix: persist the `relativePath → fileId` map at listing time, for example as JSON next to the DB keyed by source id, or in an `import_item` column. Use it in `resolve`, and relist only for paths missing from it. A cheaper partial fix is an id-derived suffix for every member of a collision group, but it still drifts when a collision appears.

**I5. "Đăng nhập lại" does not check that the account is the same one.**
- Where: `PhotoVault/App/AppModel+CloudImports.swift:118-139`.
- Google:
  - Any account is accepted, and `remoteItems` is replaced by the new pick. The hint added in `6678eb5` helps.
  - A smaller pick turns pending paths into `missing` and makes later exports of a closed import fail as `fileMissing`.
  - `drive.file` access is per app and user, so for the same account the old ids stay readable.
  - Fix: if the email matches, merge the old and new ids. Otherwise refuse with a notice.
- Dropbox:
  - `signIn.email` is ignored, so the row keeps the old email while reading another account.
  - Pending paths then resolve to that other account's files, and the wrong content is imported.
  - Fix: compare the email, or better the `account_id`, with `config.account` and refuse a mismatch.

**I6. Cloud `inspect` downloads bypass the disk guard.**
- Where: `DriveImportSource.swift:60-69` and `DropboxImportSource.swift:48-57`. `ImportStage+Ingest.swift:36` passes a fresh `ExportControl()`.
- Scenario: a 10–20 GB video is downloaded into `staging/cloud-import` with no free-space check, while exports are gated by `ResourceGuard`. Mac folders read in place, so they never had this cost.
- Fix: before inspecting a cloud item, check free space against `item.sizeBytes` plus the critical watermark (for example through `env.disk`). Or pass a control with a byte cap, and hold the job on a shortfall.

**I7. Factory reset can leave cloud grants in the Keychain.**
- Where: `AppModel+FactoryReset.swift:19-21`. Related: `AppModel+CloudImports.swift:22-31` and `83-91`.
- How a grant is left behind:
  - The accounts to delete come from DB rows read through `try?`. If the read fails, which is plausible when the owner resets because the DB is unhealthy, only `dropbox-account` is deleted.
  - A crash between the Keychain write and `startImport` leaves an `import-<id>` with no row.
  - A failed `try? removeGrant` in the `catch` leaves one too.
- In each case a live Drive or Dropbox refresh token survives "start over", which breaks AC5 and the privacy promise.
- Fix: in `SystemKeychainStore`, enumerate the service's items (`kSecMatchLimitAll`, `kSecReturnAttributes`) and delete every `import-*` item plus `dropbox-account`.

**I8. A closed cloud import with no usable grant has two opposite outcomes, and neither is visible.**
- Where: `ExportWorker+SourceFailures.swift:36-40`.
- The two outcomes:
  - Grant revoked: every pending export of that job becomes a permanent skip, one by one.
  - Token missing (no adapter): exports throw `.unavailable` and wait hourly forever, with no UI. `aFinishedCloudImportWithoutAnAdapterIsStillWaitedForNotLost` asserts this.
- `ImportFinishedRow` has no sign-in action, so neither case can be repaired except by importing again.
- This touches an ADR decision, so I am not proposing a silent change. The options:
  - (a) Keep the ADR as is, and show "cần đăng nhập lại" on finished rows that are waiting.
  - (b) Make both cases wait, and offer the sign-in action on finished rows. This fits "never lose a photo" best.
  - (c) Make both cases skip.
- Recommendation: (b).

**I9. Two streaming download implementations, and one should be removed now.**
- The two:
  - Drive `URLSessionTransport.stream` (`HTTPTransport.swift:120-140`) walks `URLSession.bytes` one byte at a time. The Dropbox file's own comment calls this "too slow for large videos", and it costs CPU on every Drive import download.
  - Dropbox `URLSessionByteStreamer` (DropboxByteStreaming.swift) uses a delegate but has the I2 bug. It also bypasses `LoggingHTTPTransport` and creates a new `URLSession` per file.
- Why now: one has a correctness bug and the other a speed problem, and they share the same contract.
- Recommendation:
  - Move the delegate streamer, with the I2 fix, into `PhotoVaultDrive` as the `URLSessionTransport: StreamingTransport` implementation, returning `(Data, HTTPURLResponse)`.
  - Have `DropboxClient.download` call `transport.streamBody` and read `Retry-After` from the response.
  - Delete `DropboxByteStreaming`, `DropboxStreamHead` and `URLSessionByteStreamer`. That is about 80 lines removed, with one tested path left.

## Minor

**M1. Drive `probe` and `list` treat a 403 on a picked item as the source being away.**
- Where: `DriveImportSource.swift:35-41` and `DriveImportListing.swift:89-91`.
- A 403 (`appNotAuthorizedToFile`, or a file unshared from the account) on `pickedIds.first`, or on any picked id during listing, holds the whole job `offline` forever.
- Fix: count only network, auth and 5xx errors as unavailable. A per-item 403 or 404 means Drive answered; skip that item.

**M2. Concurrent exports after a relaunch each run a full Drive listing.**
- Where: `DriveImportSource.swift:83`.
- `hasListed` is checked across an `await`, so with 2 concurrent exports each runs its own full listing.
- Fix: keep one in-flight listing `Task` inside `PathIndex`.

**M3. Dropbox parent-folder casing can differ between entries.**
- Where: `DropboxImportSource.swift:36-39`.
- Dropbox guarantees the case of `path_display` only for the last component. Siblings can come back as `Photos/a.jpg` and `photos/b.mov`, which splits album titles and Live Photo pairs.
- Fix: build directory names from the folder entries' own `name`, keyed by `path_lower`.

**M4. A Dropbox root folder renamed mid-import marks every pending file `missing`.**
- Where: `DropboxImportSource.swift:58-61` and `ImportStage+Ingest.swift:46`.
- Each pending file gets 409 `not_found` and is marked `missing`, instead of the job being held.
- Fix: on `fileMissing`, probe the root first.

**M5. Dropbox maps too many token-endpoint failures to "revoked".**
- Where: `DropboxAuth.swift:121-125`.
- Any non-2xx answer other than 429 or 5xx becomes `accessRevoked`, which permanently skips exports of closed imports.
- Fix: limit it to `invalid_grant`, plus a 400 or 401 whose `error` is `invalid_client`. Treat other answers as `.unavailable`.

**M6. The loopback server can swap the picked ids after a code was accepted.**
- Where: `LoopbackRedirectServer.swift:166`.
- `acceptedCallback` is stored before the `outcome == nil` check. A second request with the right `state` (a browser reload or prefetch) can replace `picked_file_ids` after the code was accepted.
- Fix: assign it inside the `accepted` lock block.

**M7. The Picker loopback timeout is 300 s.**
- Where: `GooglePickerFlow.swift:64`.
- Picking many photos across folders can take longer, and the selection is then lost.
- Fix: give the Picker 15 min or more.

**M8. The Dropbox browser keeps a stale email after "Đăng nhập lại".**
- Where: `DropboxFolderSheet.swift:84, 114-115`.
- `browser.email` is not refreshed, so a different account is labelled with the old email.

**M9. A re-signed-in import can wait for the next scheduled cycle.**
- Where: `ImportStage.swift:62` and `AppModel+CloudImports.swift:152-156`.
- The 30 s hold cooldown means the `requestSync(.manual)` just after signing in again is skipped, and the import resumes only on a later cycle.
- Fix: add a coordinator command that clears the hold and sets the job to `scanning`.

**M10. YAGNI and naming leftovers.**
- `SystemKeychainStore(service:)` (`KeychainStore.swift:20`) has no non-default caller.
- Dropbox tokens live under the service `com.annh.photovault.google`. Either document it in the README or give Dropbox its own service.
- `DropboxTokenAuthorizer.hasStoredToken` and `forget`, and `DriveImportAuth.hasGrant`, are used only by tests or not at all.
- After `6678eb5` the key helpers are aliases of `CloudTokenAccount`. Delete the aliases.

**M11. ADR 0026 overstates what factory reset does.**
- Where: `docs/decisions/0026-cloud-folder-imports.md:74`.
- It says factory reset deletes tokens "after it has tried to revoke them". The code only deletes them; fix the ADR.
- Keep it that way for Dropbox: every import copy shares the account's refresh token, and Dropbox `token/revoke` disables the whole refresh token.

**M12. The fixed Dropbox port listens only on 127.0.0.1, but the redirect says `localhost`.**
- A browser that resolves `localhost` to `::1` can reach a squatter on `[::1]:53682`.
- PKCE still blocks the code exchange.
- Fix: also listen on `::1`, or register `http://127.0.0.1:53682` if Dropbox accepts it.

**M13. Some tests do not prove what they claim.**
- `aCloudAdapterGivesTheSameResultAsAMacFolder` uses `FakeCloudSource` over a local folder, so AC1 is not exercised through the real Drive or Dropbox adapters with stubbed HTTP.
- No test covers the real `URLSessionByteStreamer` or `URLSessionTransport.stream` under task cancellation (I2).
- No test checks that paths stay stable across a relist when siblings change (I4).

**M14. A missing Dropbox account token shows the generic error banner.**
- Where: `copyDropboxAccountToken`.
- It throws `DestinationError.reauthRequired`, which falls through to `showError`. Map it to the Dropbox sign-in notice.

## Checked, no finding

- PKCE S256 and constant-time `state` on both flows. `PickerResult`, `DropboxSignIn` and `DropboxAccessToken` descriptions are redacted.
- `Dropbox-API-Arg` escapes non-ASCII and DEL as UTF-16 `\u` units. The `remotePath` traversal guard is in place.
- Dropbox root normalisation. Drive `parseIds` charset, dedupe and cap.
- Scratch files: removed by `defer`, and swept after a crash by `StagingManager.cleanupOrphans` (it walks `staging/` recursively, at startup only).
- Partial files on failure: `writer.abort()` runs on every path, except the I2 cancel path.
- Drive 401 retry: no byte reaches the sink before the retry.
- `DriveImportAuth` refreshes once at a time and stores a rotated refresh token.
- Logs carry no names, ids, emails or tokens. Dropbox RPC goes through `LoggingHTTPTransport` and logs path templates only.
- `SourceRepository.readableImports` and launch registration. No schema change; old rows decode.

## Plan follow-ups

- `plan.md` still lists every phase as `pending`, but phases 01–05 appear implemented. The project manager should sync the statuses.
- AC1: partly met (see M13).
- AC5: met for the normal path, but see I7.
- AC4 and the open/closed behaviour: as designed, but see I8.
- AC7: `swift test` passes on `1c9d99f`. I did not run a signed Release `xcodebuild`.

## Unresolved questions

1. **Same Google account for the Picker and the backup destination.** Both use one OAuth client. Does signing out or revoking the destination (`AppModel+Account`) also kill the import's grant? Google revocation appears to act on the client–user grant. Google also caps refresh tokens at 100 per client per account, so many picks or re-sign-ins could silently evict the destination token. Verify in the owner's E2E run.
2. **Shared drives.** `files.get` and `files.list` are sent without `supportsAllDrives` / `includeItemsFromAllDrives`. If the Picker offers Shared-drive items, they would 404, be skipped silently, and trigger the misleading "select the photos inside" hint.
3. **Dropbox and Unicode normalisation.** Relative paths are NFC. Does Dropbox resolve an NFC path for a file stored in NFD form (uploaded from an older Mac)? If not, those files become `fileMissing`. Test it in the E2E run with a Vietnamese file name.
