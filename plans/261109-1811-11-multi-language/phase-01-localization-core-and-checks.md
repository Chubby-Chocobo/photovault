---
phase: 01
title: "Language core and coverage test"
status: pending
priority: P2
size: M
human_effort: 1h
dependencies: []
touches:
  - Sources/PhotoVaultCore/Localization/**
  - Sources/PhotoVaultAppSupport/VietnameseFormat.swift
  - Tests/PhotoVaultCoreTests/LocalizationTests.swift
  - Tests/PhotoVaultAppSupportTests/UITextCoverageTests.swift
  - Tests/PhotoVaultAppSupportTests/VietnameseFormatTests.swift
acceptance:
  - swift test --filter "LocalizationTests|VietnameseFormatTests"
---

# Phase 01: Language core and coverage test

## Overview
The pieces every other phase uses: the language value, the `tr(vi:en:)` function, an English plural helper, language-aware number grouping, and the test that keeps Vietnamese literals out of UI code. Size: M.

## Requirements
- `Sources/PhotoVaultCore/Localization/`:
  - `public enum AppLanguage: String { case vi, en }`.
  - `public enum InterfaceLanguageChoice: String { case system, vi, en }` with `resolved(preferredLanguages: [String]) -> AppLanguage` (system → `vi` when the first preferred language starts with "vi", else `en`).
  - `public enum L10n`: `static var current: AppLanguage` (get/set through `OSAllocatedUnfairLock`, default `.vi`); `@TaskLocal static var override: AppLanguage?`; `static var language: AppLanguage { override ?? current }`.
  - `public func tr(vi: String, en: String) -> String` (plain `String` arguments, so interpolation works on both sides).
  - `L10n.plural(_ count: Int, one: String, other: String) -> String` for the English side.
- `VietnameseFormat.integer/bytes/gigabytes`: grouping "." and decimal "," for `vi` (unchanged), "," and "." for `en`. Signatures unchanged.
- `UITextCoverageTests` (AppSupport tests): reads the Swift files under `PhotoVault/`, `Sources/PhotoVaultAppSupport/`, `Sources/PhotoVaultEngine/` (repo root from `#filePath`) and fails, listing file:line, for a string literal containing Vietnamese letters that is not the argument of `vi:` and is not on a line ending in `// l10n: verbatim`. Comment lines (`//`, `///`) are skipped. Multi-line literals (`"""`) are flagged (UI code has none today).

## Tests first
- `LocalizationTests`: `tr` returns each side for `override` = vi/en; default is vi; `withValue` does not leak to a sibling task; `current` set/get; `resolved` for `["vi-VN","en"]`, `["en-US","vi"]`, `[]`; plural one/other.
- `VietnameseFormatTests`: existing cases unchanged; new `en` cases under `L10n.$override.withValue(.en)`.
- `UITextCoverageTests` starts red (today's literals) — mark it `.disabled("enabled in phase 05")` until phases 02–03 land, so CI stays green in between.

## Implementation Steps
1. Write the tests; see them fail.
2. Add the Localization files and the formatting change.
3. Run the filter; leave the coverage test disabled.

## Success Criteria
- [ ] Core and format tests pass; coverage test reports today's literals when enabled locally.

## Risk Assessment
The coverage scan is a heuristic (a literal on a line after `vi:` but not its argument); keep the rule simple — the literal must be immediately preceded by `vi:` — and fix code to fit it rather than widen the rule.
