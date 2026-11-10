---
description: Swift code, module, testing, error-handling and privacy conventions for PhotoVault
---

# Code standards

These rules come from the code as it is built. Where this file and the code disagree, fix whichever one is wrong in the same change.

## Language and build

- Swift 6 language mode with strict concurrency (`swiftLanguageModes: [.v6]` in `Package.swift`). A change must build with no warnings in the files it touches.
- The deployment target is macOS 14. macOS 27-only APIs are not used ([decision 0006](../decisions/0006-macos-27-apis-unavailable.md)).
- Dependencies: GRDB only. A new package needs a decision record.
- Build and test with `swift test`. The app builds unsigned with `xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Debug build CODE_SIGNING_ALLOWED=NO`.

## Modules

- The dependency direction is fixed: `PhotoVaultCore` ← `Store`, `Photos`, `Drive`, `Local`, `Engine` ← `AppSupport` ← the app target. `PhotoVaultTestSupport` is for tests only. See [system-architecture.md](../architecture/system-architecture.md).
- Core holds the contracts. These are the protocols, entities, `JobTransitions`, `ErrorClassifier` and the policies. Every job state change goes through `JobTransitions.apply`.
- Logic that does not need SwiftUI or AppKit goes in `PhotoVaultAppSupport`, where it can be tested. The app target is UI and launch glue.

## Files and naming

- Swift files use PascalCase, named after their main type or as `Type+Concern.swift`. This replaces the generic kebab-case rule for code files. Docs, scripts and config stay kebab-case.
- Keep files under about 300 lines. Split them along real boundaries (a type, a concern).
- No dumping-ground files (`Utils.swift`, `Helpers.swift`).

## Concurrency

- Shared mutable state lives in actors. View models are `@MainActor`. Values that cross actors are `Sendable`.
- Do not `await` inside a GRDB write closure. Network and PhotoKit calls happen outside transactions.
- Blocking file I/O on destinations runs on the destination's serial queue, not on the Swift concurrency pool.
- Owner commands run in `SyncCoordinator`'s exclusive lane. A command must never call `run(trigger:)` from inside the lane.

## Data safety

- **Write the database before the side effect.** Reserved IDs, upload intents, sessions and move jobs are persisted before the remote call.
- **No delete operation exists in `Destination`.** The engine trashes only shortcuts it created. Local code removes only its own `.part` and probe files.
- Destinations throw only `DestinationError`, and `ErrorClassifier` is the single mapping from errors to retry classes.
- The SQLite connection uses `synchronous = FULL` and `fullfsync`. Schema changes are new migrations, never edits to a shipped one.

## Errors and logging

- Do not catch and swallow errors. Classify them, record the job transition, or surface them to the owner.
- Logs and activity events never contain file names, coordinates, tokens, session URIs or e-mail addresses. Log the error type, not its message. File logs go through `LogRedactor`.
- UI copy is bilingual: write every interface string as `tr(vi: "…", en: "…")`, never a bare Vietnamese literal; English counts use `L10n.plural`. `UITextCoverageTests` enforces it (a language's own name or a folding letter takes `// l10n: verbatim`). Tests pin a language with `L10n.$override.withValue(.en)`, never by setting `L10n.current`. See [0022](../decisions/0022-interface-languages.md).
- Never localize what is written to destinations: folder names (`Camera Uploads`, `Screenshots`, `Saved`, `By device`, `By place`, `Favorites`, day and place folders) and sidecars stay the same whatever the interface language.
- Messages never include file paths or photo names.

## Tests

- Use Swift Testing (`@Test`, `#expect`). Write the test first for behaviour changes.
- Tests are deterministic: use `TestClock` and the fakes in `PhotoVaultTestSupport`, poll with a timeout (`pollUntil`) instead of sleeping for a fixed time, and do not share mutable clocks between parallel tests.
- A loaded CI runner can stretch any real-time window many times over. Do not let a result depend on a short real-time window running out or not: inject the clock or the timeout (a test seam with the same default), wait for a signal, and keep real timeouts in tests only as hang guards, far above what the work takes.
- For crash safety, use fault injection (`CrashPoint`) and rebuild the engine over the same database.
- Camera detection on real files is guarded at two levels:
  - `RawHeaderFixtureTests` runs on the opening bytes of real RAW files kept in git (`Tests/PhotoVaultPhotosTests/Fixtures/RawHeaders/`, about 3.4 MB).
  - `RawCameraFallbackTests` and `HeaderReadTests` use synthetic bytes: the fallback for cameras macOS does not know, and the header read that classifies photos without RAW.
  - `MediaCorpusTests` runs on complete files that stay out of git. They are listed with checksums and expectations in `Fixtures/MediaCorpus/manifest.json` and fetched by `scripts/fetch-media-corpus.py`. CI caches them and always runs this suite; locally it runs when `PHOTOVAULT_MEDIA_CORPUS` is set.
  - A change to how files are read must keep both green. When a result changes on purpose (for example a new macOS reads a new format), update the manifest in the same change.
- Do not put plan IDs, phase numbers or review finding codes in test names, code comments or commit messages.
