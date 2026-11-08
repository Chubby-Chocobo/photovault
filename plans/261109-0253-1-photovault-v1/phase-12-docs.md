---
phase: 12
title: "Docs: README, sidecar schema, decisions, spikes, test report"
status: pending
priority: P2
size: M
human_effort: 2-3h
dependencies: [11]
touches:
  - README.md
  - docs/
acceptance:
  - test -f docs/sidecar-schema.md
  - test -f docs/test-report.md
  - test -d docs/decisions
  - test -d docs/spikes
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 12: Docs

## Overview
Everything spec §12 asks to be written down. Size: M — several documents, no code.

## Requirements
- README: build (Xcode, `swift test`), Google Cloud setup (Drive API, External consent, scopes, publish In production, Desktop OAuth client, `Config/Secrets.xcconfig`), signing with a Personal Team and running from `/Applications`, NAS setup, configuration, known limits (spec §12 list plus FR-20 rule-3 scan risk, FR-73 TOCTOU, FR-85 coordinates sent to Apple, no client-side encryption, FR-94 notes), uninstall.
- `docs/sidecar-schema.md` generated from `SidecarBuilder` fields, with a JSON and an XMP example.
- `docs/decisions/` one file per [VERIFY] default and per deviation from the spec.
- `docs/spikes/` M0-1…M0-6 procedures, what to measure, where to record, and which setting/default each result changes.
- `docs/test-report.md`: T1–T43 table with automated test name or "manual" and a result column for the owner.
- `docs/architecture/system-architecture.md`: module graph, pipeline, data flow.

## Implementation Steps
1. Write docs from code (read the code, not the plan).
2. Cross-check every FR behaviour maps to a test or a decision file (see Audit additions).

## Success Criteria
- [ ] Acceptance files exist; links resolve.

## Risk Assessment
- Docs drift from code: written last, from the code.

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- The FR cross-check is by behaviour: each FR maps to a test name or a `docs/decisions/` file, not just a grep hit for the code.
