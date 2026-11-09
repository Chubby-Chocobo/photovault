---
phase: 04
title: "Docs and reset"
status: completed
priority: P3
size: S
human_effort: 30m
dependencies: [03]
touches:
  - docs/requirements/photovault-spec-v1.md
  - docs/decisions/0023-day-folders-and-place-name-rule.md
  - docs/decisions/README.md
  - README.md
acceptance:
  - swift test
---

# Phase 04: Docs and reset

## Requirements
- Spec FR-40, §8.7, FR-82, FR-104–106 updated; decision 0023; README layout section.
- Install: the owner trashes the old Drive root first (so onboarding does not offer it for reuse); quit the app; move the whole `Application Support/PhotoVault` data folder aside (database, WAL, backups — owner-approved wipe); install; launch; onboarding creates a new root.
