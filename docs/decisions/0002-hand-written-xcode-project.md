# 0002 Hand-written Xcode project over the local SPM package

- **Status:** Accepted
- **Spec refs:** §6 (SPM, no extra dependencies), §7
- **Review trigger:** when the app target needs a second target or a generator becomes necessary

## Context

The app needs an `Info.plist`, entitlements and the App Sandbox, which an SPM-only executable cannot carry. Spec §6 allows only SPM and forbids extra tools unless a reason is written down.

## Decision

`PhotoVault.xcodeproj` is a small hand-written project. It uses file-system synchronized groups (`PBXFileSystemSynchronizedRootGroup`) and a local package reference (`XCLocalSwiftPackageReference`, `relativePath = .`). All logic lives in the package. The app target is a thin shell (`PhotoVault/PhotoVaultApp.swift`).

Rejected alternatives: XcodeGen or Tuist (an extra tool outside spec §6).

## Consequences

- No project generator. Target settings are edited in Xcode or in `Config/*.xcconfig`.
- Build settings come from `Config/Base.xcconfig`. It is wired as the base configuration for the app target.
- The app target has no logic of its own. Its current body is a placeholder menu bar item; the real UI is still to be written.
