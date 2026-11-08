# 0003 Own OAuth PKCE and loopback listener, no AppAuth

- **Status:** Accepted
- **Spec refs:** FR-02, FR-03, §6 (AppAuth or own PKCE, with a reason)
- **Review trigger:** when Google changes loopback or PKCE rules, or the owner decides to adopt AppAuth

## Context

Spec §6 allows AppAuth or a custom PKCE and loopback implementation, but requires the reason to be written down. AppAuth-iOS needs its HTTP server add-on on macOS.

## Decision

Use an own implementation:

- `PKCE.swift`: RFC 7636 S256 verifier and challenge, plus a random `state`.
- `OAuthClient.swift`: builds the authorization URL (`access_type=offline`, `prompt=consent`), exchanges the code, refreshes tokens and revokes them.
- `LoopbackRedirectServer.swift`: a one-shot listener on `127.0.0.1` with an ephemeral port (`NWEndpoint.hostPort(host: "127.0.0.1", port: 0)`). It answers only the callback path (other paths get 404 and do not use the single slot) and times out after 300 seconds (`defaultTimeout`).
- Scope: `https://www.googleapis.com/auth/drive.file openid email`.

## Consequences

- About 300 lines to maintain. The code is covered by `Tests/PhotoVaultDriveTests` (`OAuthClientTests`, `OAuthPrimitivesTests`, `AuthSessionTests`), with a fake transport and a fake clock.
- No third-party code handles tokens.
- The ID token is checked for audience and expiry (`IDToken.swift`).
