# 0004 Swift Testing for package tests

- **Status:** Accepted
- **Spec refs:** §11 (unit tests with fakes)
- **Review trigger:** none expected

## Context

Spec §11 needs unit tests for state transitions, naming, eligibility and policies, many of them parameterized.

## Decision

All package tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). XCTest is not used. Swift Testing ships with the Swift 6 toolchain, so no test dependency is added.

## Consequences

- Test targets need the Swift 6 toolchain (the package is `swift-tools-version:6.1`).
- Test support lives in `Tests/*/Support` and in the `PhotoVaultTestSupport` target (fakes shared by the test targets).
