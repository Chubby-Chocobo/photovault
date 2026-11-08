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
- UI copy is Vietnamese. Messages never include file paths or photo names.

## Tests

- Use Swift Testing (`@Test`, `#expect`). Write the test first for behaviour changes.
- Tests are deterministic: use `TestClock` and the fakes in `PhotoVaultTestSupport`, poll with a timeout instead of sleeping for a fixed time, and do not share mutable clocks between parallel tests.
- For crash safety, use fault injection (`CrashPoint`) and rebuild the engine over the same database.
- Do not put plan IDs, phase numbers or review finding codes in test names, code comments or commit messages.
