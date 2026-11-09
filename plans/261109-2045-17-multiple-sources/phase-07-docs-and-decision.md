---
phase: 07
title: "Docs, spec amendment, decision 0024"
status: completed
priority: P2
size: S
human_effort: 0.5-1h
dependencies: [05, 06]
touches:
  - docs/decisions/0024-multiple-sources-and-folder-import.md
  - docs/decisions/README.md
  - docs/requirements/photovault-spec-v1.md
  - docs/sidecar-schema.md
  - docs/architecture/system-architecture.md
  - docs/architecture/codebase-summary.md
  - README.md
acceptance:
  - test -f docs/decisions/0024-multiple-sources-and-folder-import.md
  - grep -q "0024" docs/decisions/README.md
  - grep -q "x:<sha256>" docs/requirements/photovault-spec-v1.md
  - grep -q "\"source\"" docs/sidecar-schema.md
---

# Phase 07: Docs, spec amendment, decision 0024

## Overview
This phase records the owner's amendment and documents the source model so `docs/` stays true. Size S: docs only, no contract change beyond describing the code.

## Requirements
- `0024-multiple-sources-and-folder-import.md`: status Accepted. Spec refs §2, §3, §8.1, §8.2, §8.4, §8.8, §8.12, §15, and new FR-110..FR-116. It records the plan.md decisions (content keys, dedupe rule, imports as new arrivals, cancel semantics, sidecar block, Google Photos API limit). Review trigger: a continuous non-Photos source lands, or the owner reports a wrong duplicate.
- Spec (`docs/requirements/photovault-spec-v1.md`), marked "sửa đổi 2026-11-09, issue #17, quyết định 0024" as 0023 did:
  - §2: drop "Dropbox" and "nhiều tài khoản Google" from the non-goals, and add goal 9 "nhiều nguồn, cùng một cách tổ chức".
  - §3: terms Nguồn, Import job, and asset key `x:<sha256>`.
  - New §4.13 "Nguồn & nhập một lần": FR-110 sources list, FR-111 folder import (read-only bookmark, recursive, packages skipped), FR-112 grouping, FR-113 metadata/date rule, FR-114 dedupe, FR-115 cancel, FR-116 progress and summary.
  - §8.1: content key. §8.2: `source`, `import_item`, `asset.source_id`. §8.4 step 3: import stage. §8.8: imports get `inserted_at` = ingest time. §8.12: the `source` block. §15: the deferred sources list.
- `docs/sidecar-schema.md`: the `source` object (kind, name, path, dateSource) and `localIdentifier` for imports. Re-check the date line.
- `system-architecture.md` / `codebase-summary.md`: `SourceRegistry`, `ContentSource`, `LocalFolderSource`, `ImportStage` in the module map and the cycle.
- README: feature line and known limits (only folders on this Mac; Photos access still required; the reverse duplicate case; keep the folder until the job completes).

## Related Code Files
- Create: `docs/decisions/0024-multiple-sources-and-folder-import.md`
- Modify: the files in `touches`

## Implementation Steps
1. Read each doc before editing it (documentation rule), and compare it with the merged code from phases 01–06.
2. Write 0024 and add the README index row.
3. Amend the spec sections. Update the sidecar schema, the architecture docs and the README.
4. Do a whole-docs sweep for "Không làm … Dropbox" and "nhiều tài khoản Google": none may be left outside history notes.

## Success Criteria
- [ ] The acceptance greps pass, and every claim names a symbol that exists in the code.

## Risk Assessment
- Spec FR numbers collide with another open branch. Low: the last code is FR-106, and the open plans (#11, #12, #16) add none.
