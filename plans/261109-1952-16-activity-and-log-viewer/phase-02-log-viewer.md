---
phase: 2
title: "Log viewer window"
status: completed
priority: P2
size: M
human_effort: 1h
dependencies: [1]
touches:
  - Sources/PhotoVaultAppSupport/LogReader.swift
  - PhotoVault/Views/Log/**
  - PhotoVault/PhotoVaultApp.swift
  - PhotoVault/App/**
  - PhotoVault/Views/MenuBar/**
  - PhotoVault/Views/Settings/AdvancedTab.swift
  - Tests/PhotoVaultAppSupportTests/**
acceptance:
  - swift test --filter LogReader
---

# Phase 2: Log viewer window

## Implementation Steps
1. AppSupport `LogReader`: parse `<ISO date> [LEVEL] category: message` lines from the current and rotated files, newest first, capped; unparsable lines kept as plain text; level filter and search.
2. App: `LogView` window (`WindowID.log`), local times, level badge, category, message; selectable text; refresh on file change; copy visible lines; "Mở thư mục log".
3. Menu bar "Xem log" and Advanced tab open the window.
4. Tests for parsing, ordering across rotated files, filtering.

## Success Criteria
- [x] A non-technical owner can read and copy the log without Finder.
