# Full audit: Google Drive, OAuth and Photos adapter

Branch `review/full-codebase-audit` @ 451f1c3 (release/0.1.0 head). Read-only on code.
Scope: every file in `Sources/PhotoVaultDrive/**` and `Sources/PhotoVaultPhotos/**`, plus their tests. I read the engine call sites only where needed to confirm a failure.

Checks I ran:
- `swift test --filter "PhotoVaultDriveTests|PhotoVaultPhotosTests"`: 128 tests in 28 suites passed.
- A scratch binary cancelled a `URLSession.upload(for:from:)` Task. It throws `NSURLErrorDomain -999` and `error is CancellationError == false`.
- A scratch binary printed the `PHPhotosError.Code` raw values. The codes in `PhotosErrorMapper` are correct; the gaps are listed in I2.

No Critical findings: no token leak, no auth bypass and no path to data loss was found.

## Important

**I1. When the geocoder finds nothing for a cell, geocoding of every older cell stops for good (FR-84, FR-106).**
- Where: `CLGeocoderReverseGeocoder.swift:18-19`.
  - An empty result throws `GeocodingError.noResult`.
  - `CLError.geocodeFoundNoResult` (open sea, which CLGeocoder reports as an error) is passed through as a thrown error.
- How the scheduler reacts (`GeocodeScheduler.swift:73-79`): it counts this as a failure, backs off for up to 30 min and ends the pass (`:48`, `:61`).
- Why it never moves on: `missing()` returns cells in a fixed order (`ORDER BY prio DESC, newest DESC, a.geo_cell`, `:158`), and a failed cell is never cached. So the same cell comes first again on every pass.
- Scenario:
  1. Some photos were taken at sea or near a coast. Cells are 0.01° (`Snapshots.swift:17`), so a cell centre can fall about 500 m offshore.
  2. Every cell whose newest photo is older than that cell's is never geocoded.
  3. The By-place view and place folder names stay empty for most of the backfilled library, and one wasted request is made per pass.
- Fix:
  - Map an empty result and `CLError.geocodeFoundNoResult` to `GeoPlace()` (all fields nil).
  - The scheduler already caches such a place as "nothing to name" (`:56-59`, `identity == nil`).
  - Throw only for network, throttling and cancellation errors.

**I2. Errors that mean the whole Photos library is unavailable are treated as item errors, and they use up the export attempts (FR-23).**
- Where: `PhotosErrorMapper.swift:15-23`. These codes fall to `.other`, which `ErrorClassifier.swift:54` treats as `.itemLevel`:
  - `libraryVolumeOffline` (3114)
  - `relinquishingLibraryBundleToWriter` (3142)
  - `switchingSystemPhotoLibrary` (3143)
- `PhotosSourceError.libraryUnavailable`, which is classified `.destinationLevel`, is never produced anywhere (grep shows only the declaration and the classifier).
- Scenario:
  1. The system library lives on an external SSD (common for large libraries). The SSD sleeps or is unplugged during backfill.
  2. Every export attempted in each pass fails with 3114 and adds one to `export_attempts`.
  3. After 8 failures the resources go to `deferred` (24 h retry), and after 30 days to `skipped`.
  4. All of this happens although nothing is wrong with the assets.
- Fix: map 3114, 3142 and 3143 to `.libraryUnavailable`. Consider mapping `notEnoughSpace` (3305) to the disk-guard path rather than an item error.

**I3. A PhotoKit request that stops making progress holds an export slot forever.**
- Where: `ResourceRequestSession.swift:33-42` and `stream` (`:54-76`). There is no inactivity deadline and no `progressHandler`. `ExportControl` only stops on bytes or disk. There is no stall watchdog anywhere in the engine (grep for `stall`/`watchdog`: none).
- Scenario:
  1. In Optimize Mac Storage mode, iCloud Photos pauses or never delivers. Examples: Low Power Mode, sync paused, or the `cloudphotod` process stuck.
  2. With `isNetworkAccessAllowed = true`, `requestData` neither delivers nor completes.
  3. Two such assets fill both slots (`maxConcurrentExports = 2`), and the export pipeline stops until the app restarts.
  4. Classification reads (`readClassificationHeader`) are stuck the same way.
- Confidence: plausible, not reproduced. M0-1 should confirm it.
- Fix:
  - Track the time of the last chunk in the session.
  - Cancel when no chunk has arrived for N minutes and surface `.networkError`, which is item-level with backoff.

**I4. "Đổi tài khoản" and "Dùng tài khoản khác" cannot reach a second Google account in a normal browser (FR-08).**
- Where: `OAuthClient.swift:56` sends `prompt=consent` only.
- Google's documentation: `select_account` is the value that makes Google ask for an account. Without it, a browser signed in to one Google account goes straight to consent for that account.
- Scenario:
  1. The owner presses Đổi tài khoản.
  2. The browser shows consent for the current account A.
  3. `beginAccountChange` sees the same `sub`, so it takes the same-account path and commits A again (`AppModel+Account.swift:85-95`).
  4. Onboarding's `useAnotherAccount` signs out, which revokes the token, then signs in to the same account again.
- Fix: send `prompt=select_account consent`. That still forces a refresh token.

## Suggestion

**S1. `URLError(.cancelled)` escapes the Drive module and is counted as a job failure.**
- Where: `DriveHTTP.swift:49` deliberately rethrows `.cancelled`. The `DriveAPI` doc says "Throws `DestinationError` only".
- How the engine sees it: `UploadAttempt.swift:50` only treats `CancellationError` as cancellation. Anything else goes to `handleFailure`, which records "unexpected error" (`UploadAttempt+Errors.swift:21-23`), adds one to `attempts` and applies a backoff.
- When it happens: on `cancelUploads` (root change, account change, destination removal).
  - If `changeDriveAccount`'s checker or commit then throws, nothing is reset.
  - The in-flight jobs keep the penalty and the comment at `UploadRunner.swift:93-94` ("jobs stay `uploading`") does not hold.
- Fix: in `DriveHTTP.attempt`, turn `URLError.cancelled` into `CancellationError` (and in `OAuthClient.perform`, which maps it to `.transient("network -999")`).

**S2. `list(under:)` does not match its protocol contract, so one engine path is dead in production.**
- Where: `GoogleDriveDestination.swift:152-156`. The protocol says "nil = the whole backup tree" (`Destination.swift:228`). What the adapter does:
  - It always adds `trashed=false`.
  - With nil it lists every app-created item in the account, not just the root.
  - With a folder it lists only direct children.
- `FakeDestination.listItems` behaves differently: it returns the root's subtree recursively and includes trashed items.
- Effect:
  - The `where item.trashed` scan in `RootProblemService.swift:111` never yields anything against real Drive. "Khôi phục giúp tôi" therefore only restores folders the database knows about, for example not a folder created after the backup that FR-52 restored.
  - The tests pass only because of the fake.
- Fix:
  - Document the real semantics in the protocol: account-wide, not trashed, children only.
  - Make the fake match them.
  - Give `untrash` a separate `trashed=true` query.

**S3. 403 classification for shortcuts is too narrow for FR-103.**
- Where: `DriveErrorMapper.swift:52-56` accepts only `insufficientPermissions` and `forbidden`.
- Drive also uses `insufficientFilePermissions` and `appNotAuthorizedToFile`. If `drive.file` refuses shortcuts with one of those, every shortcut fails item-level and keeps retrying, instead of `viewsNotPermitted` turning the views off.
- Fix: add both reasons now, then confirm in M0-3.

**S4. The browser says "Đã xong" before the credentials are stored.**
- Where: `OAuthClient.swift:85` responds with success. After that, `GoogleAuthSession.signIn` can still fail on "refresh token missing" or on the Keychain write (`GoogleAuthSession.swift:59-62`).
- Example: -34018 in an unsigned build, or a locked Keychain. The browser tab says done while the app shows an error.
- Fix: pass a completion back so that `respond(success:)` runs after `install` (or after staging).

**S5. Video metadata blocks a cooperative thread and leaks the task on timeout.**
- Where: `ImageIOMetadataReader.swift:53-62`. `DispatchSemaphore.wait` (up to 30 s) is called from `ExportWorker.swift:184`, which runs in an async context.
- On timeout, the detached task is not cancelled and keeps the `AVURLAsset` open.
- Two concurrent exports fit the cooperative pool, so this is not a deadlock today. It is the pattern to avoid.
- Fix: make `MetadataReading` async, or run it on a dedicated queue and cancel the task when it times out.

**S6. A root check that hits a 429 or 5xx reports Drive as offline.**
- Where: `GoogleDriveDestination.swift:60-62`. `rateLimited` and `server` classify as `.transient`, which falls through to `.unavailable(.offline)`.
- Effect: the owner sees "offline" while the network is fine. It clears at the next cycle.
- Fix: return a backoff status, or keep the previous status for transient errors.

**S7. An appProperties pair over the limit fails the same way on every try, yet it is retried as an item error.**
- Where: `GoogleDriveDestination.swift:186-188` throws `itemRejected("appProperties pair too long")` without the `permanent:` prefix.
- Effect: 8 attempts, then 30 days of `deferred`, for a failure that will repeat identically every time.
- Today only `pvArchiveTZ` or a future key could exceed the limit; the codec hashes the others.
- Fix: use `ErrorClassifier.permanentReasonPrefix`.

## Edge cases checked by scouting
- Callers of `list(under:)`: `RemoteInventory` filters by `isUnderRoot` (correct with account-wide listing). `IntegrityChecker` probes each missing id (correct, but one `files.get` per file under a trashed folder). `RecoveryTriggers.hasBackupFiles` would flag any other PhotoVault root, but the probe key is set by `reset`, so this is not reached in practice.
- URLSession cancellation semantics (verified empirically, S1).
- How the geocode scheduler orders cells and stops a pass (I1).

## Verified sound (not re-reported)
- **PKCE and state:** S256 PKCE; a 48-byte verifier and 32-byte state from `SecRandomCopyBytes`.
- **Loopback redirect:**
  - The `state` comparison runs in constant time and comes before `error` or `code` is read.
  - A wrong `state` gets a 400 and does not end the flow.
  - Idle connections are closed after 10 s.
  - `finish` cancels the open connections.
  - Responses carry `Connection: close`, `no-store` and `no-referrer`.
  - The listener is bound to 127.0.0.1.
  - The code continuation resumes exactly once: there is an `outcome` latch, and cancellation arriving before `awaitCode` is handled.
- **ID token:** `aud`, `iss`, `exp` and `sub` are checked. Skipping the signature check is justified.
- **Refresh:**
  - Single flight.
  - A generation counter discards a refresh that finished after `install` or `signOut`, so no stale token is cached and no rotated token rewrites a deleted Keychain item.
  - Every token-endpoint failure that is not transient becomes `reauthRequired`.
- **Account change:** the staged account stays in memory and is committed atomically under the `pendingStage` id. `StagedAccount` does not refresh. Every token holder redacts its description.
- **Keychain:** data-protection keychain, `AfterFirstUnlockThisDeviceOnly`, not synchronizable. Sign-out deletes the item first and revokes best-effort.
- **Logging:**
  - `LoggingHTTPTransport` logs method, host and path template only (IDs become `:id`).
  - No query string, header or body is logged.
  - Bearer tokens go only to `https://*.googleapis.com` session URIs.
- **Drive queries:**
  - `q` literals escape `\` and `'`.
  - The form encoding allows only unreserved characters.
  - Every create, update and upload asks for `fields` including `id`, `md5Checksum`, `trashed` and `parents`.
  - Pagination follows `nextPageToken`.
  - The stream cancels its task on termination.
- **Errors:** 403 throttling reasons map to `rateLimited`, and `Retry-After` is read as delta-seconds or an HTTP date. 409 is resolved by `files.get` and a compare (name, mimeType, parent, targetId).
- **Resumable upload:**
  - Chunks are a multiple of 256 KiB, and offsets are `Int64`, so files over 4 GB are fine.
  - 404 or 410 on a chunk gives `sessionExpired`, and `parentMissing` applies only to the session-start request.
  - There is a stall guard, and finalisation uses `bytes */N`.
  - A resume is refused when the MD5 or size differs from the checkpoint.
  - The MD5 is checked before `done`, and a mismatch is not released from the cap.
  - The daily cap is reserved before the first byte and persisted through `onDailyCapChange`.
- **Write limiter:** the `DriveWriteLimiter` token bucket covers session start and every metadata write.
- **PhotoKit fetching and requests:**
  - Fetches use `includeHiddenAssets` and `includeAllBurstAssets`. The default source types exclude Shared Albums, which matches FR-19.
  - Requests set `isNetworkAccessAllowed = true`.
  - Cancellation is race-free: a cancel that arrives before the request id is known is replayed.
  - The continuation resumes once, through PhotoKit's single completion.
- **Export writing:**
  - `StreamingFileWriter` hashes inline, in delivery order.
  - A partial file is deleted on abort or failure.
  - A disk-guard stop maps to `.cancelled`, not to an item error.
- **Classification:** the `HeaderClassifier` is guarded by a lock and capped at 32 MiB. On overflow it falls back to reading the full file. A truncated spill from an early stop is discarded.
- **Persistent changes:** the token is archived with secure coding; an unreadable token becomes `tokenExpired`. The persistent-change error codes 3105 and 3210 are mapped correctly.

## Unresolved questions
- **Zero-byte uploads:** `PUT` with `Content-Range: bytes */0` and an empty body finalises the upload in `FakeDriveServer`. Has it been tried against real Drive (M0-3)?
- **I3:** does `requestData` with network access really hang without completing when iCloud Photos sync is paused? (M0-1.)
- **S3:** which 403 reason does Drive return for a shortcut operation that `drive.file` refuses? (M0-3.)

Status: DONE
Summary: All in-scope Drive, OAuth and Photos files were reviewed and 128 tests pass. No Critical findings. Four Important:
- I1: a no-result geocode stops all older place names.
- I2: an offline library volume uses up export attempts.
- I3: a stalled iCloud request holds an export slot.
- I4: `prompt` lacks `select_account`, so a different account cannot be chosen.
Seven Suggestions.
