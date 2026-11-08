---
title: "PhotoVault 1.0 — macOS Photos backup to Google Drive and local/NAS"
status: in-progress
priority: P1
size: L
human_effort: 40-70h
branch: feat/photovault-v1
sources:
  - "tracker: github-issue:Chubby-Chocobo/photovault#1"
  - "spec: file:docs/requirements/photovault-spec-v1.md"
authoritative: "spec: file:docs/requirements/photovault-spec-v1.md"
---

# PhotoVault 1.0

Implements the whole spec in issue #1 (copied verbatim to `docs/requirements/photovault-spec-v1.md`; FR/NFR/T codes below refer to it): a sandboxed macOS menu-bar app (Swift 6, SwiftUI, GRDB, SPM) that backs up the system Photos library to one Google Drive root and 0..n local/NAS folders, never deleting backup data.

The owner chose to build M1–M5 now, before the M0 spikes have been run on real data. Every assumption marked [VERIFY] in the spec is implemented as the spec's default and recorded in `docs/decisions/`; the M0 procedures that need the owner's library, Google account and NAS are written to `docs/spikes/` for the owner to run.

## Principles

- The spec wins over convenience. Where the spec is silent, choose the option that cannot lose or duplicate backup data (NFR-01), then the simpler one.
- Never delete backup data at any destination. `Destination` has no delete operation.
- Pure logic lives in `PhotoVaultCore` behind protocols (`PhotosSource`, `Destination`, `LayoutPolicy`, `ReverseGeocoding`, `Clock`), so the pipeline is unit-tested with fakes.
- Tests first for core logic: every state transition in spec 8.3, naming, layout, eligibility, classification, sidecars, place naming, view diffing, rate limiting, disk guard, recovery matching.
- No dependency outside spec §6 without a written reason.

## Architecture (module graph)

```
PhotoVaultCore      contracts (models, persisted entities, protocols, DestinationError, codecs), pure rules
                    (state machine, eligibility, naming, layout, classifier, error classes) and policies
                    (backoff, token bucket, disk guard, place naming, sidecar JSON/XMP, view diff, device names)
PhotoVaultStore     GRDB schema (spec 8.2), migrations, repositories, VACUUM INTO backups
PhotoVaultPhotos    PhotoKit PhotosSource, streaming export (MD5+SHA-256), ImageIO/AVFoundation metadata
PhotoVaultDrive     OAuth PKCE + loopback, Keychain, Drive v3 REST client, resumable upload, GoogleDriveDestination
PhotoVaultLocal     LocalFolderDestination: atomic no-overwrite writes, folder locks, bookmarks, destination.json
PhotoVaultEngine    ChangeTracker, scan/incremental/reconciliation, ExportWorker + staging + ResourceGuard,
                    fan-out uploads, MoveWorker, PlaceNamer, edit gate, sidecars, ViewBuilder,
                    RecoveryService, IntegrityChecker, SyncCoordinator (spec 8.4), instance lock
PhotoVaultTestSupport  fakes (photos source, destinations, geocoder, clock, disk) shared by tests
PhotoVault (Xcode app) composition root, MenuBarExtra UI, onboarding, Settings, activity, notifications,
                    login item, scheduler/power/network monitors, logging
```

Dependencies: Core ← Store, Photos, Drive, Local; Engine ← Core + Store; App ← all.

## Phases

| # | Phase | Status | Size | Depends on |
|---|---|---|---|---|
| 01 | [Scaffold: SPM package, Xcode app project, CI, config](phase-01-scaffold.md) | done | M | — |
| 02 | [HTML mockups of every screen](phase-02-mockups.md) | done | M | — |
| 03 | [Core contracts: models, entities, protocols, state machine, fakes](phase-03-core-contracts.md) | done | L | 01 |
| 03b | [Core policies: rate limiting, disk guard, places, sidecars, devices, views](phase-03b-core-policies.md) | done | M | 03 |
| 04 | [Store: GRDB schema, repositories, backups](phase-04-store.md) | done | L | 03 |
| 05 | [Photos adapter, export streaming, metadata reader](phase-05-photos-adapter.md) | done | M | 03 |
| 06 | [Google Drive: OAuth, Keychain, REST, resumable upload](phase-06-google-drive.md) | done | L | 03 |
| 07 | [Local/NAS destination](phase-07-local-destination.md) | done | M | 03 |
| 08 | [Engine: change tracking, export, fan-out, sync cycle](phase-08-engine-pipeline.md) | done | L | 04 |
| 09 | [Organization & metadata: day folders, places, sidecars, edits, views](phase-09-organization-metadata.md) | done | L | 03b, 08 |
| 10 | [Hardening: recovery, reconciliation, integrity, rebuild](phase-10-recovery-integrity.md) | done | L | 07, 09 |
| 11 | [App: menu bar, onboarding, Settings, notifications](phase-11-app-ui.md) | done | L | 02, 05, 06, 07, 10 |
| 12 | [Docs: README, sidecar schema, decisions, spikes, test report](phase-12-docs.md) | done | M | 11 |

Phase 03 (contracts) is written by the controller as code; it is the contract. Phases 03b and 04–07 then run in parallel (separate folders, separate `--scratch-path`); none of them may change Core contract types. Phase 02 runs in parallel with 01–03.

## Acceptance criteria (from spec §12, scoped to what an agent can prove)

- [ ] `swift build` and `swift test` pass from a clean checkout; `xcodebuild -scheme PhotoVault build CODE_SIGNING_ALLOWED=NO` succeeds.
- [ ] Every FR is implemented as described, or has a reason in `docs/decisions/`.
- [ ] Unit tests cover the list in spec §11 "Unit" with fakes.
- [ ] Every [VERIFY] has a recorded conclusion or is listed in `docs/spikes/` as pending the owner's M0 run, with the default the code uses.
- [ ] Extension points from spec §7 exist: `Destination` (with capabilities), `LayoutPolicy`, `ViewRule`, `Transform` (identity).
- [ ] `docs/sidecar-schema.md` exists and matches `SidecarBuilder`.
- [ ] README covers build, Google Cloud setup, signing, NAS, configuration, known limits, uninstall.
- [ ] No secrets in git; `Config/Secrets.xcconfig` is gitignored with an `.example`.
- [ ] T1–T43: unit-level equivalents automated where possible; the manual run is a checklist in `docs/test-report.md` for the owner.

## Decisions
### Geocoding input privacy
- Chosen: send only ~0.01° cell centres; exclude hidden (when Hidden upload is off) and deleted assets from place naming and By place
- Alternatives: raw coordinates; include every asset with GPS
- Why: FR-85 promises ~1 km rounding; hidden photos must not leak into visible folder names; the spec is silent on hidden assets here
- Review later: yes

### Sandbox container and unsigned builds
- Chosen: DB, staging and lock live in the sandbox container; an unsandboxed build refuses to start without `--dev-container`
- Alternatives: allow unsandboxed runs on Application Support; App Group container
- Why: unsigned and signed builds would otherwise use two DBs and two locks against the same Drive root (T41, NFR-01)
- Review later: yes

### Keychain class
- Chosen: data-protection keychain, AfterFirstUnlockThisDeviceOnly, not synchronizable
- Alternatives: legacy file keychain with ACL
- Why: no code-signature ACL prompts across rebuilds (T24), never leaves this Mac
- Review later: yes

### Upload generation tracking
- Chosen: `uploading_gen` captured at `pending → uploading`; `done_gen = uploading_gen`; `target_gen = max(target_gen, content_gen)`
- Alternatives: spec 8.3 literal `done_gen = target_gen`
- Why: the literal rule marks a newer edit as done when an older upload finishes (T30b); this keeps the spec's intent "never lose the last update"
- Review later: no

### Scope before M0
- Chosen: build M1–M5 now, implement every [VERIFY] with the spec default, record each in docs/decisions/, write the M0 procedures to docs/spikes/ for the owner
- Alternatives: run M0 first and stop (spec §14); scaffold plus core logic only
- Why: the owner explicitly asked for the full build in this run; M0 needs the owner's library, Google account and NAS, which an agent cannot use
- Review later: yes

### Xcode project generation
- Chosen: a hand-written minimal .xcodeproj (file-system synchronized groups) that depends on the local SPM package
- Alternatives: XcodeGen or Tuist (extra tool dependency); SPM-only executable (cannot carry Info.plist, entitlements, sandbox)
- Why: spec §6 asks for SPM and no extra dependencies; all logic is in the package, the app target is a thin shell
- Review later: no

### OAuth implementation
- Chosen: own PKCE + loopback listener on Network.framework, no AppAuth
- Alternatives: AppAuth-iOS (macOS loopback needs its HTTP server add-on)
- Why: about 300 lines, fully unit-testable, no third-party code handling tokens; spec §6 allows it with a stated reason
- Review later: no

### Test framework
- Chosen: Swift Testing (`import Testing`) for all package tests
- Alternatives: XCTest
- Why: ships with the Swift 6 toolchain, parameterized tests suit the naming and transition tables
- Review later: no

### Documentation paths
- Chosen: the spec's paths `docs/decisions/`, `docs/spikes/`, `docs/sidecar-schema.md`, `docs/test-report.md`
- Alternatives: ADF layout `docs/architecture/decisions/`, `docs/testing/`
- Why: the spec's acceptance criteria name these paths; the spec is authoritative
- Review later: no

### Deployment target and macOS 27 APIs
- Chosen: macOS 14; `PHAssetExtendedMetadata` and `prefetchAssetExtendedMetadata` are not in the macOS 26.5 SDK, so sidecars write `"extendedMetadata":"unavailable"` and the code path is isolated behind a capability check
- Alternatives: raise the target; stub the API
- Why: spec §6 says macOS 14+; the SDK on this machine has no such API, so it cannot be compiled or verified
- Review later: yes

### Push and PR despite spec §14 "không push"
- Chosen: push the feature branch and open a PR into release/0.1.0, merge with --ship
- Alternatives: keep everything local
- Why: the owner explicitly asked to set up the GitHub remote and run /vibe --ship
- Review later: no

### Edited JPEG extension
- Chosen: edited JPEGs are named `(edited).JPG`; other edited files use the upper-cased UTI extension
- Alternatives: `(edited).JPEG` straight from the UTI
- Why: matches iPhone and camera naming the owner already sees; recorded in `docs/decisions/0021-edited-extension-casing.md`
- Review later: no

### Owner decisions surfaced by the app
- Chosen: the app shows engine decisions only with data the engine persists (folder-trashed cards carry no folder name; the zero-match recovery card offers "Thử khôi phục lại" or "Tiếp tục không dùng dữ liệu cũ")
- Alternatives: persist folder path and recovery stats in the engine for richer cards
- Why: avoids a schema change late in the build; the Activity window already holds the details
- Review later: yes

### Small-file reads on local destinations
- Chosen: `LocalFolderDestination.readSmallFile` (no symlinks, 1 MB cap) feeds recovery's sidecar reader
- Alternatives: read sidecars through `FileManager` from the app
- Why: keeps every byte read from the NAS behind the same fd-relative, no-follow access as writes
- Review later: no

### Crash scope and owner commands during a sync
- Chosen: NFR-01 covers power loss and kernel panic (SQLite `synchronous=FULL` + `fullfsync`); owner commands run in one exclusive lane with the sync cycle, which yields at pass boundaries
- Alternatives: `synchronous=NORMAL` (faster, loses recent commits on power loss); per-destination locks for commands
- Why: a lost reserved-ID commit after power loss re-creates the file on Drive; a single lane is the simplest way to stop integrity checks and root changes racing uploads
- Review later: yes (measure write throughput on a large backfill)

## Audit Review

### Session — 2026-11-09
**Findings:** 34 raw, 30 after dedup (28 accepted, 2 rejected)
**Severity breakdown:** 6 Critical, 18 High, 6 Medium

| # | Finding | Severity | Disposition | Applied To |
|---|---------|----------|-------------|------------|
| 1 | Destination contract cannot persist reserved IDs/sessions before side effects (duplicates after crash) | Critical | Accept | 03, 06, 07, 08 |
| 2 | No persisted entity types in Core; parallel phases would diverge | Critical | Accept | 03 |
| 3 | No shortcut/root/untrash/list contract reachable from Engine | Critical | Accept | 03, 06 |
| 4 | Recovery never triggered and does not gate uploads; `pvRoot` missing | Critical | Accept | 04, 06, 08, 10 |
| 5 | Zero-match recovery re-uploads the library | Critical | Accept | 10 |
| 6 | `done_gen = target_gen` loses the last edit; staging generations | Critical | Accept | 03, 04, 09 |
| 7 | PhotosSource contract drift (names, errors, export callback, header result, metadata) | High | Accept | 03, 05 |
| 8 | Wire vocabulary undefined (sidecar res codes, appProperties, DestinationError, SystemConditions) | High | Accept | 03 |
| 9 | Phase 03 too big; T4b/T30b misplaced | High | Accept | 03, 03b, 08, 09, 10 |
| 10 | No conformance test for real destinations; geocoder unowned | High | Accept | 03, 05, 06, 07 |
| 11 | `target_gen` equality vs counter → stuck jobs | High | Accept | 03, 04 |
| 12 | Fake-only crash tests; NAS `.part` never swept | High | Accept | 07, 10 |
| 13 | Startup recovery misses move/shortcut/replace states, `session_md5` | High | Accept | 08, 09 |
| 14 | Classification reads bypass ResourceGuard and bucket | High | Accept | 03b, 08 |
| 15 | Promotion during upload leaves file outside day folder | High | Accept (as Medium) | 08, 09 |
| 16 | Redaction covers only refresh token; file log PII | High | Accept | 03, 06, 11 |
| 17 | Loopback bind/single-shot/timeout; ID token checks; sign-out must wipe Keychain | High | Accept | 06 |
| 18 | Symlink defence only on last component; cleanup scope | High | Accept | 07 |
| 19 | `alreadyExists` handling and Drive query escaping | High | Accept | 06 |
| 20 | Local recovery trusts NAS data; restore skips FR-51 | High | Accept | 04, 10 |
| 21 | Synchronous requestData handler vs actor guard; Mutex needs macOS 15 | High | Accept | 05 |
| 22 | Early "Make/Model absent" misclassifies permanently | High | Accept | 05 |
| 23 | GRDB 7.12 needs tools 6.1; CI runner/billing | High | Accept | 01 |
| 24 | Unsandboxed builds split DB/lock | High | Accept (modified: refuse without `--dev-container`) | 08, 11 |
| 25 | FR behaviours with no owner (FR-11, 13, 33, 47 untrash, 61 durations, 71, 75, 08 reset, 106 refresh, 22, NFR-08) | High | Accept | 04, 05, 07, 08, 10, 11, 12 |
| 26 | Keychain class and error mapping | Medium | Accept | 06 |
| 27 | Unsanitized display components and XMP escaping | Medium | Accept | 03, 03b |
| 28 | Geocoding raw coordinates / hidden assets | Medium | Accept | 03, 03b, 09 |
| 29 | Store duplicates 8.3 in SQL; serial-queue race tests; VACUUM in transaction | Medium | Accept | 04 |
| 30 | Core cannot use UTType with Foundation only; ResourceType raw values | Medium | Accept | 03 |
| — | Drop HTML mockups (scope critic) | Medium | Reject: the owner explicitly asked for mockups; 375px rule removed instead | 02 |
| — | Split mockups from Phase 11 dependency | Medium | Reject: mockups are the UI reference for phase 11 and finish early | — |

### Whole-Plan Consistency Sweep
- Decision deltas: two-step creates, persisted entities in Core, `uploading_gen`, recovery gate, Core split into 03/03b, T4b → 10, T30b → 09, tools 6.1, sandbox container rule.
- Updated stale text: phase 01 risk and tools version, phase 02 success criterion, phase 08 test list and `readClassificationHeader` name, phase 09 geocoder owner and dependency on 03b, phase 10 dependency on 07 and recovery risk, phase 12 cross-check, plan.md phases table, architecture block and parallelism note.
- Unresolved contradictions: none.

## Validation Log

### Session 1 — 2026-11-09 (auto mode: answered by the plan's Principles, recorded as decisions)
Verification pass skipped: the audit above carried evidence-backed verification of 4 roles.
1. **Build everything before M0?** Chosen: yes (owner's explicit answer). See Decisions "Scope before M0".
2. **Mockup format?** Chosen: interactive HTML (owner's answer).
3. **Who writes the Core contract?** Chosen: the controller, as code, before any parallel phase (Principles: contracts must not drift). Applied to plan.md and phase 03.
4. **What happens to a [VERIFY] that cannot be verified here?** Chosen: implement the spec default behind a setting or capability flag, record it in `docs/decisions/`, list the owner procedure in `docs/spikes/`. Applied to phases 05, 06, 07, 12.
5. **Merge target and strategy?** Chosen: PR `feat/photovault-v1 → release/0.1.0`, squash (release-train flow); the release → main step is out of scope for this run.
6. **CI cost on a private repo?** Chosen: one macOS job with path filters and cancel-in-progress. Applied to phase 01.
