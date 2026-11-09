---
phase: 05
title: "Docs, decision 0026, privacy page"
status: pending
priority: P3
size: S
human_effort: 0.5-1h
dependencies: [04]
touches:
  - docs/**
  - README.md
  - site/**
acceptance:
  - test -f docs/decisions/0026-cloud-folder-imports.md
---

# Phase 05: Docs

- Decision 0026: cloud one-time imports. Copy the decisions from plan.md.
- README:
  - Owner setup: enable the Google Picker API; the Dropbox app (Full Dropbox, three permissions, redirect `http://localhost:53682/oauth2/callback`, App key in `Config/Secrets.xcconfig`).
  - How to import, and the known limits (folder children under `drive.file`; double download).
- Spec: new FRs after FR-118. Sidecar schema: the `source.kind` values. Architecture: the Dropbox module and the cloud adapters.
- Site privacy page:
  - Drive imports read only the files picked in Google's Picker.
  - Dropbox reads the folder the owner chooses, read-only.
  - Tokens stay in the Keychain on the Mac; nothing goes to our servers.
