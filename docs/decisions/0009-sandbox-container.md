# 0009 State lives in the sandbox container; unsandboxed runs need `--dev-container`

- **Status:** Accepted (review later)
- **Spec refs:** FR-54, NFR-01, §9, T41
- **Review trigger:** when an App Group or a second build target is proposed

## Context

A signed (sandboxed) build and an unsigned build would otherwise use two databases and two locks against the same Drive root. That risks duplicate uploads (NFR-01) and breaks the single-instance rule (FR-54, T41).

## Decision

`ContainerLocator.resolve(...)` picks the state directory:

| Launch | State root | Condition |
|---|---|---|
| Sandboxed app | `<Application Support>/PhotoVault/` (inside the container) | `APP_SANDBOX_CONTAINER_ID` is set |
| Unsandboxed, with `--dev-container` | `~/Library/Application Support/PhotoVault-dev/` | argument present |
| Unsandboxed, no flag | refuses to start (`EngineError.unsandboxedBuild`) | otherwise |

The state root holds `photovault.sqlite`, `Staging/`, `Backups/`, `Logs/` and the lock file `photovault.lock` (`InstanceLock.fileName`). The Xcode scheme (`PhotoVault.xcscheme`) has `--dev-container` in its run arguments, switched off by default.

Alternatives rejected: allowing unsandboxed runs on Application Support (shares nothing with the signed build, so the two can overlap); an App Group container (an extra entitlement the spec does not list).

## Consequences

- A dev-container run starts with an empty database. Pointing it at a root the signed app uses triggers recovery (FR-51) rather than a fresh upload. Do not run both against the same root at the same time.
- Signing with a Personal Team does not move the state. Only the presence of the sandbox variable decides.
