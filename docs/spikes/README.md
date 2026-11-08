# M0 spikes

Spec §10 requires these measurements before the defaults are trusted. They need the owner's Photos library, Google account and NAS, so the build agent could not run them. Each file below is the procedure for one spike, with a Results table for the owner to fill in.

Status of every spike: **pending owner run**.

## Index

| Spike | Question | Changes (short) | Owner time | Wall time | Status |
|---|---|---|---|---|---|
| [M0-1](m0-1-icloud-export-disk.md) | Does Photos reclaim disk after exporting iCloud-only originals? | watermarks, backfill rate, free-space metric | about 1 h | about 25 h | pending owner run |
| [M0-1b](m0-1b-resource-bytes-and-mapping.md) | Are exported bytes exact? Which resources and UTIs map to what? | RAW detection, resource plan, cancel handling | 1–2 h | 1–2 h | pending owner run |
| [M0-2](m0-2-change-history-and-identifiers.md) | What do change history, cloud IDs and adjustment data really do? | change handling, cloud-ID mapping, edit gate, deployment target | 2–3 h | 2–3 h | pending owner run |
| [M0-3](m0-3-google-drive-behaviour.md) | How does Drive behave for resumable upload, shortcuts, IDs and quota? | views, cap, token bucket, appProperties limit | 3–4 h | 1 day (upload runs) | pending owner run |
| [M0-4](m0-4-signing-sandbox-and-filesystems.md) | Do signing, sandbox, Keychain, bookmarks and filesystems behave? | entitlements, bookmark handling, rename fallbacks | 3–4 h | 2 days (Personal Team re-signs) | pending owner run |
| [M0-5](m0-5-exif-and-header-classification.md) | Is EXIF read correctly, and how many bytes does classification need? | classifier, metadata reader, video timeout | 2–3 h | 2 h | pending owner run |
| [M0-6](m0-6-geocoder-quality.md) | Does `CLGeocoder` return the structured fields the place names need? | place names, language, rate limit | 1–2 h | 1 day (for the 24-hour key check) | pending owner run |

## How the owner runs a spike

1. Read the spike file and the "Changes" section first. Decide whether the result would change anything you care about before spending the hours.
2. Build the probe described below. Probes are not in the repo. Keep them outside the repo, so the spec rule "no changes outside the project" still holds.
3. Run the steps. Write the raw output to a log file outside the repo.
4. Fill in the Results table in the spike file. Do not delete rows; mark skipped ones as skipped with a reason.
5. For each default that the result changes, edit the constant or setting named in the spike file, and update the matching decision file: status `Pending M0` becomes `Accepted` (with the result), or the decision is rewritten.
6. Record any §8.5 stop condition (M0-1: Photos never reclaims originals) in [decisions/0001](../decisions/0001-build-before-m0.md) and stop before enabling backfill.

## Probe setup (shared)

- Create a scratch SwiftPM executable (for example `~/photovault-spikes/probe/`, outside the repo). Add the repo as a local dependency with `.package(path: "<repo root>")` and reference its library products (`PhotoVaultPhotos`, `PhotoVaultDrive`, `PhotoVaultLocal`, `PhotoVaultCore`) by name. If SwiftPM reports the package identity as unknown, use the lowercased folder name of the repo.
- Run the probe from Terminal on the Mac that holds the library. macOS asks for Photos access the first time: allow it for the app that started the probe.
- Never write to the main library except through the steps a spike names. Use a second, disposable Photos library for destructive tests (M0-2 rebuild and cloud-ID tests).
- Delete any exported copies after a run. They are test copies, not backups.

## Results convention

Every spike file ends with a Results table left empty for the owner, under the heading "Owner to fill in". Numbers go in the table with units (GB, seconds, bytes, codes). Free-text conclusions go under the table.
