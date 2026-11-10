# Decisions

One file per decision. Each records the status, the context, the decision, its consequences, the spec references and the trigger that should reopen it.

Status values:

- **Accepted:** the decision stands. The code follows it.
- **Pending M0:** the code uses a spec default that an M0 spike has not yet confirmed. The spike named in the file decides whether the default changes.

Spec references use the FR, NFR, §, and T codes of [photovault-spec-v1.md](../requirements/photovault-spec-v1.md).

| # | Decision | Status | Spec refs |
|---|---|---|---|
| [0001](0001-build-before-m0.md) | Build M1–M5 before the M0 spikes | Accepted | §10, §14 |
| [0002](0002-hand-written-xcode-project.md) | Hand-written Xcode project over the local SPM package | Accepted | §6, §7 |
| [0003](0003-own-oauth-pkce.md) | Own OAuth PKCE and loopback listener, no AppAuth | Accepted | FR-02, FR-03 |
| [0004](0004-swift-testing.md) | Swift Testing for package tests | Accepted | §11 |
| [0005](0005-docs-paths.md) | Spec paths for decisions, spikes and the sidecar schema | Accepted | §12 |
| [0006](0006-macos-27-apis-unavailable.md) | macOS 27 extended-metadata APIs unavailable; target macOS 14 | Accepted | FR-10, FR-91, §6 |
| [0007](0007-push-despite-spec-14.md) | Push the feature branch and open a PR despite spec §14 | Accepted | §14 |
| [0008](0008-geocoding-privacy.md) | Geocoding sends only grid-cell centres; hidden and deleted excluded | Accepted | FR-84, FR-85, NFR-06 |
| [0009](0009-sandbox-container.md) | State in the sandbox container; unsandboxed runs need `--dev-container` | Accepted | FR-54, NFR-01, T41 |
| [0010](0010-keychain-class.md) | Data-protection Keychain, this device only | Accepted | FR-03, NFR-06, T24 |
| [0011](0011-upload-generation-tracking.md) | `done_gen` is the generation uploaded, not `target_gen` | Accepted | §8.3, T30b |
| [0012](0012-photos-adapter-defaults.md) | Photos adapter defaults for unverified PhotoKit behaviour | Pending M0 | FR-12, FR-20, FR-30, FR-34 |
| [0013](0013-drive-defaults.md) | Google Drive defaults for unverified Drive behaviour | Pending M0 | FR-43, FR-44, FR-47, FR-103 |
| [0014](0014-local-nas-defaults.md) | Local and NAS defaults for unverified filesystem behaviour | Pending M0 | FR-70, FR-73, FR-75 |
| [0015](0015-disk-guard-watermarks.md) | Disk guard: watermark comparisons, hysteresis, GB as GiB | Pending M0 | FR-31, §8.5 |
| [0016](0016-daily-upload-cap-700gb.md) | Drive daily upload cap: 700 × 10⁹ bytes | Pending M0 | FR-49 |
| [0017](0017-token-bucket-lanes.md) | Token bucket: upload and metadata lanes | Pending M0 | FR-49, §8.5 |
| [0018](0018-backoff-full-jitter.md) | Retry backoff: full jitter, 1 second to 30 minutes | Accepted | NFR-04 |
| [0019](0019-place-naming-edge-choices.md) | Place naming: edge-case choices | Pending M0 | FR-80 to FR-83, §8.11 |
| [0020](0020-view-diff-choices.md) | View diff: how shortcuts converge | Accepted | FR-100 to FR-103, §8.13 |
| [0021](0021-edited-extension-casing.md) | Edited file extensions: upper-case UTI extension | Accepted | FR-41 |
| [0022](0022-interface-languages.md) | Interface languages: Vietnamese and English text pairs, switched live | Accepted | issue #11 |
| [0023](0023-day-folders-and-place-name-rule.md) | Day folders in every branch; fixed place-name languages | Accepted | FR-40, FR-82, FR-104–106, §8.7 |
| [0024](0024-multiple-sources-and-folder-import.md) | Several sources, one layout: source model and one-time folder import | Accepted (continuous sources superseded in part by 0029) | §2, §3, §8.1, §8.2, §8.4, §8.8, §8.12, §15, FR-110–116 |
| [0025](0025-old-layout-block-and-reset.md) | Upgrading from 0.1.0: block the old layout, start over with a factory reset | Accepted | FR-117, FR-118, FR-08, FR-51, §8.7 |
| [0026](0026-cloud-folder-imports.md) | One-time import from a Google Drive or Dropbox folder: Picker, folder browser, revoked grants | Accepted (Drive scope superseded by 0030) | §2, §9, §15, FR-119–123 |
| [0027](0027-by-lens-view.md) | By lens view: opt-in, EXIF lens name shortened for Apple | Accepted | FR-107 |
| [0028](0028-split-day-by-place.md) | Split a camera day into one folder per province | Accepted | FR-40, FR-81, FR-83, §8.2, §8.4, §8.7, §8.11, §8.15, T28 |
| [0029](0029-photos-only-continuous-source.md) | Photos is the only continuous source; the extension mechanism is designed, not built | Accepted | §2, §8.1, §15, FR-110, FR-120 |
| [0030](0030-drive-import-reads-folder-contents.md) | Google Drive import reads folder contents with drive.readonly; grant deleted when the import ends | Accepted | FR-119, FR-122, FR-123 |

Adding a decision: copy the next free number, keep the same five sections, and link it from this table and from the affected spec or code notes. A `[VERIFY]` default that the code uses goes in a group file (0012–0014) or its own file, and its spike goes in [docs/spikes/](../spikes/README.md).
