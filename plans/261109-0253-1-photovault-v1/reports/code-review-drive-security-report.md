# Code review: Drive, OAuth, Photos export, logging, config, CI

Branch `feat/photovault-v1` @ 9433489 (base 7cad755). Read-only review.
Checks run: `swift test --filter "PhotoVaultDriveTests|PhotoVaultPhotosTests|PhotoVaultAppSupportTests"`, 187 tests in 35 suites, all passed. I also checked the loopback binding directly: an NWListener built the same way shows up in `lsof` as `TCP 127.0.0.1:<port> (LISTEN)`.

No Critical findings (no credential leak, auth bypass or irreversible data loss found).

## Important

1. **An account change makes the new account's tokens live before the owner confirms it, and the engine keeps running against the old account's state.**
   - Where: `Sources/PhotoVaultDrive/GoogleAuthSession.swift:31-39` writes the refresh token and access token right away. `PhotoVault/App/AppModel+Account.swift:49-61` does not pause Drive when the account changed. `PhotoVault/Views/Settings/AccountSheets.swift:49-66` lets the owner press Cancel at `chooseRoot`, or during `signingIn`, which leaves the Task running.
   - Failure: the owner opens "change account" while Drive is `active` and signs in as B. Account A's root and folder IDs are still in the DB. Uploads then go out with B's token. A POST with `parents=[A day folder]` returns 404. `upload()` maps that to `folderMissing` (`GoogleDriveDestination.swift:94-95`). The engine then runs `invalidate` and `markBranchMissing` (`UploadAttempt.swift:271-275`), so A's done files are marked `missingRemote` and A's folder cache is wiped. If the owner cancels, B's credentials stay in the Keychain and the DB still says A. This breaks FR-08 ("confirm → reset").
   - Fix: sign in to a staged credential that is not live, and swap it in only in `applyDriveRoot`. At minimum, set Drive to `paused` before `signIn()` and restore the old status on cancel.

2. **A 404 on a resumable chunk PUT is treated as "parent folder missing".**
   - Where: `ResumableUploader.swift:83-87` turns any non-200/308 into `DriveErrorMapper.error`, so 404 becomes `.notFound`. `GoogleDriveDestination.swift:91-96` wraps the whole `uploader.upload` (session start and transfer) in `catch .notFound → parentMissing`.
   - Failure: Drive drops or expires the session in the middle of a transfer. Drive answers 404 for an unknown session, and `FakeDriveServer.swift:165` models this too. The result is `folderMissing`: the branch is marked `missingRemote`, the folder cache is cleared, and a duplicate folder gets created. If the parent is the root, the result is `rootMissing` and the whole destination pauses. After `resumeUpload`, the same 404 comes out as a bare `notFound`, which is an item-level error, instead of `sessionExpired`.
   - Fix: in `transfer`, map 404 and 410 to `.sessionExpired`, as `probe` already does at line 105. Apply `parentMissing` only to errors from `startSession`.

3. **The daily upload cap (FR-49) resets on every launch and can be overshot by uploads running in parallel.**
   - Where: `PhotoVault/Engine/AppEnvironment.swift:114-115` builds `GoogleDriveDestination` with the default `DailyUploadCap()`. `dailyCapState()` (`GoogleDriveDestination.swift:39`) has no callers, so nothing saves or restores it.
   - Failure: a quit, crash or launch-at-login restart sets usage to 0, so the 700 GB / rolling 24 h guard is no protection against Google's 750 GB/day limit.
   - Overshoot: `checkCap` runs before the upload's `await`, and `record` only runs in `finish` (`GoogleDriveDestination.swift:87,172-174,183`). Concurrent uploads on the reentrant actor all pass the check, so the cap can be exceeded by (number of parallel uploads) × (file size).
   - Also: the FR-49 token bucket for Drive writes is missing. `TokenBucket` is used only by `ResourceGuard`, for the export rate.
   - Fix: store the cap entries in the store, load them in `AppEnvironment`, and reserve bytes in `checkCap`.

4. **A refresh that is still running can write stale tokens after sign-out or sign-in.**
   - Where: `GoogleAuthSession.swift:56-71` cancels `refreshing`, but `refresh()` (lines 85-89) resumes after `await task.value` and writes `cached` without checking anything. It also writes any rotated refresh token back to the Keychain.
   - Failure 1: the refresh response arrives while `signOut` is waiting on `revoke`. An access token comes back into the cache, and a rotated token would recreate the Keychain item that was just deleted.
   - Failure 2: the refresh finishes after `signIn()` for account B. B's cache is overwritten with A's token.
   - Fix: add a generation counter that `signIn` and `signOut` bump, and drop results from an older generation.

5. **`resumeUpload` ignores the checkpoint's MD5 and size (FR-44: "compare session_md5; resume only if it matches").**
   - Where: `GoogleDriveDestination.swift:100-105` takes `session` but only uses `sessionRef`. The caller does not compare either (`UploadAttempt.swift:197-200`, which also passes `totalBytes: request.content.size` instead of the stored value).
   - Failure, different content: staging is lost and the re-export differs, which is the case FR-44 anticipates. The old session is resumed at the old offset, so the remote file is old bytes followed by new bytes. That produces `checksumMismatch` and uses up the FR-45 budget of 3 mismatches.
   - Failure, different size: `probe` sends `bytes */<newSize>`, and Drive will most likely answer with a 4xx, not 404/410. That surfaces as `itemRejected` instead of `sessionExpired`, so a new session is never opened.
   - Fix: if `session.md5 != request.content.md5` or `session.totalBytes != size`, throw `.sessionExpired`.

## Minor

6. **Some 403 reasons are misclassified.**
   - Where: `ErrorClassifier.swift:60-61` (called from `DriveErrorMapper.swift:38-41`) treats only `userRateLimitExceeded` and `rateLimitExceeded` as rate limits.
   - Failure: `dailyLimitExceeded` and `sharingRateLimitExceeded` become `itemRejected`, which uses up per-job attempts. In views, `isForbidden` (`DriveErrorMapper.swift:44-47`) turns any 403 `itemRejected` into `viewsNotPermitted`, which is permanent, so a quota-style 403 permanently disables a shortcut operation.
   - Also: `retryAfter` (line 33-35) ignores the HTTP-date form of `Retry-After`.

7. **Token-endpoint errors are reported as item-level.**
   - Where: `OAuthClient.swift:116-122,142-149`.
   - Failure: during a refresh, anything other than `invalid_grant`, 401, 429 or 5xx turns into `itemRejected`. Examples: a 400 `unauthorized_client`, "drive.file scope not granted", "token response malformed". `DriveHTTP.send` throws it per request, so every queued job uses up attempts and moves towards `skipped` instead of the destination going to `reauthRequired`.
   - Fix: map every token-endpoint failure to `.reauthRequired`, or to a transient destination-level error.

8. **The loopback server can be aborted or kept busy by local clients.**
   - Wrong state ends the flow: a request on `/oauth2/callback` with the wrong `state` calls `finish(.stateMismatch)` (`LoopbackRedirectServer.swift:116-119`). That ends the one-shot flow, so any local process or web page that probes the port can abort sign-in. The "Done" page is also shown on state mismatch and on `access_denied`.
   - Idle connections are never closed: accepted connections are not cancelled by `finish` or by the timeout, and there is no per-connection deadline (`:83-105`). A client that opens a socket and sends nothing keeps its NWConnection forever.
   - Fix: ignore a mismatched state and keep waiting. Track connections and cancel them in `finish`.

9. **Header classification holds the whole file in memory and re-parses it many times.**
   - Where: `HeaderClassifier.swift:39-46,55-57`.
   - Failure: for images without Make/Model (screenshots, saved or edited JPEG/PNG, large panoramas), `absent` is only concluded at `statusComplete`. Until then `buffer` grows to the full file size, and the whole prefix is passed to `CGImageSourceUpdateData` every 64 KiB. For a 30 MB file that is about 470 full re-parses, and the full file sits in memory for each concurrent classify. The ResourceGuard estimate is 1 MiB (`ClassifyWorker.swift:23`).

10. **The resumable loop has no forward-progress guard.**
   - Where: `ResumableUploader.swift:86` resets `recoveries = 0` on every 308.
   - Failure 1: a 308 whose `Range` does not advance makes the loop re-send the same 8 MiB forever.
   - Failure 2: a 308 that reports `offset == size` sends a zero-length `bytes size-(size-1)/size` instead of finalising with `bytes */size`.

## Checked and not a problem

These were checked against the code or run, not assumed:
- **Loopback binding:** the listener is bound to 127.0.0.1 only. Confirmed with `lsof`. The test at `OAuthPrimitivesTests.swift:79` does not prove this, because a client that connects to 127.0.0.1 always sees that as the local address.
- **State and PKCE:** `state` is compared in constant time before `error` or `code` is read. PKCE uses S256 with a 48-byte verifier and a 32-byte state from `SecRandomCopyBytes`.
- **Keychain:** data-protection keychain, `AfterFirstUnlockThisDeviceOnly`, not synchronizable. Sign-out deletes the item first.
- **ID token:** `aud`, `iss`, `exp` and `sub` are checked. Skipping the signature check is justified: the token comes over TLS straight from the token endpoint.
- **Drive queries:** `DriveQuery.literal` escapes `\` and `'`.
- **Bearer token destinations:** the token is sent only to `https://*.googleapis.com` session URIs.
- **Redaction:** `OAuthTokens`, `SignInResult` and `DestinationError` descriptions are redacted. The HTTP log records only method, host and path template.
- **Log files:** created with mode 0600.
- **CI:** workflows pin actions by SHA, use no secrets, and pass `BASE`/`HEAD` through env. Only the tag job has `contents: write`.
- **Entitlements:** match spec §6. No hardened-runtime exceptions.

## Unresolved questions

- The data-protection keychain needs an `application-identifier` entitlement, which comes from a provisioning profile. With Personal Team signing that has no profile, or with an unsigned `--dev-container` build, `SecItemAdd` will likely return -34018. That shows up as `transient("keychain status -34018")` and makes sign-in impossible. Has this been verified (M0-4)?
- Is the FR-49 Drive write token bucket deliberately left until after M0-3, or was it missed?
