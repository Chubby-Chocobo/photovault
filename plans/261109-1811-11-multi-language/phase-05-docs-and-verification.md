---
phase: 05
title: "Docs and verification"
status: completed
priority: P3
size: S
human_effort: 30m
dependencies: [02, 03, 04]
touches:
  - Tests/PhotoVaultAppSupportTests/UITextCoverageTests.swift
  - README.md
  - docs/decisions/0022-interface-languages.md
  - docs/decisions/README.md
  - docs/conventions/code-standards.md
  - docs/architecture/codebase-summary.md
acceptance:
  - swift test
---

# Phase 05: Docs and verification

## Overview
Enable the coverage test, record the decisions, document the convention, run everything. Size: S.

## Requirements
- Remove the `.disabled` trait from `UITextCoverageTests`.
- Decision record 0022 (inline pairs, live switch, default, separate place-name language, destination names never localized).
- code-standards: "UI text is `tr(vi:en:)`; never a bare Vietnamese literal; destination names are never wrapped."
- README: the Interface language setting. codebase-summary: `L10n` and `VietnameseFormat` note.

## Implementation Steps
1. Enable test. 2. Docs. 3. Full `swift test`, signed build, screenshots in both languages.

## Success Criteria
- [ ] Full suite green with the coverage test on; screenshots reviewed.
