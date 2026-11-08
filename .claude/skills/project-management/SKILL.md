---
name: project-management
description: "Tracks progress, updates plan statuses, hydrates Claude Tasks, and generates status reports."
user-invocable: true
when_to_use: "Invoke for progress tracking, plan status, or handoffs."
category: utilities
keywords: [project, progress, status, reports]
argument-hint: "[task: status, hydrate, sync, report]"
metadata:
  author: adf
  version: "1.0.0"
---

# Project Management

Project oversight and coordination using Claude native Tasks with persistent plan files.

**Principles:** Token efficiency | Concise reports | Data-driven insights

## When to Use

- Checking project status or progress across plans
- Updating plan statuses after feature completion
- Hydrating/syncing Claude Tasks with plan files
- Generating status reports or summaries
- Coordinating documentation updates after milestones
- Verifying task completeness against acceptance criteria
- Cross-session resume of multi-phase work

## Tool Availability

`TaskCreate`, `TaskUpdate`, `TaskGet`, `TaskList` are Claude Code's default task tools. The legacy `TodoWrite` replaces them only when `CLAUDE_CODE_ENABLE_TASKS=0` is set.

**Fallback behavior:** If Task tools error, use `TodoWrite` for progress tracking. Plan file sync-back (checkbox updates, YAML frontmatter) works identically without Task tools. Core PM workflow remains functional.

## Core Capabilities

### 1. Task Operations
Load: `references/task-operations.md`

Use `TaskCreate`, `TaskUpdate`, `TaskGet`, `TaskList` to manage session-scoped tasks (CLI only; see Tool Availability above).
- Create tasks with metadata (phase, priority, size, planDir, phaseFile)
- Track status: `pending` → `in_progress` → `completed`
- Manage dependencies with `addBlockedBy` / `addBlocks`
- Coordinate parallel agents with scoped ownership

### 2. Session Bridging (Hydration Pattern)
Load: `references/hydration-workflow.md`

Tasks are ephemeral. Plan files are persistent. The hydration pattern bridges them:
- **Hydrate:** Read plan `[ ]` items → `TaskCreate` per unchecked item
- **Work:** `TaskUpdate` tracks progress in real-time
- **Sync-back:** Reconcile all completed tasks against all phase files, update `[ ]` → `[x]`, update YAML frontmatter status
- **Resume:** Next session re-hydrates from remaining `[ ]` items

### 3. Progress Tracking
Load: `references/progress-tracking.md`

- Scan `./plans/*/plan.md` for active plans
- Parse YAML frontmatter for status, priority, size, human_effort
- Count `[x]` vs `[ ]` in phase files for completion %
- Cross-reference completed work against planned tasks
- Verify acceptance criteria met before marking complete

### 4. Documentation Coordination
Load: `references/documentation-triggers.md`

Trigger `./docs` updates when:
- Phase status changes, major features complete
- API contracts change, architecture decisions made
- Security patches applied, breaking changes occur

Delegate to `docs-manager` subagent for actual updates.

### 5. Status Reporting
Load: `references/reporting-patterns.md`

Generate reports: session summaries, plan completion, multi-plan overviews.
- Use naming: `{reports-path}/pm-{date}-{time}-{slug}.md`
- In reports, prefer brevity over full sentences; use tables over prose
- List unresolved questions at end

## Workflow

```
[Scan Plans] → [Hydrate Tasks] → [Track Progress] → [Update Status] → [Generate Report] → [Trigger Doc Updates]
```

1. `TaskList()` — check existing tasks first
2. If empty: hydrate from plan files (unchecked items)
3. During work: `TaskUpdate` as tasks progress
4. On completion: run full-plan sync-back (all phase files, including backfill for earlier phases), then update YAML frontmatter
5. Generate status report to reports directory
6. Delegate doc updates if changes warrant

## Mandatory Sync-Back Guard

When updating plan status, never mark only the currently active phase.

1. Sweep all `phase-XX-*.md` files under the target plan directory.
2. Reconcile every `TaskUpdate(status: "completed")` item to phase metadata (`phase` / `phaseFile`).
3. Backfill stale checkboxes in earlier phases before marking later phases done.
4. Update `plan.md` status/progress from real checkbox counts.
5. If any completed task cannot be mapped to a phase file, report unresolved mappings and do not claim full completion.

## Plan YAML Frontmatter

All `plan.md` files must have:

```yaml
---
title: Feature name
status: in-progress  # pending | in-progress | completed
priority: P1
size: M
human_effort: 2-4h
branch: feature-branch
tags: [auth, api]
created: 2026-02-05
---
```

`plan.md` may also carry `sources` and `authoritative`, and each phase file `touches` and `acceptance`; see `../adf-plan/references/plan-contract.md`.

Update `status` when plan state changes.

## Quality Standards

- All analysis data-driven, referencing specific plans and reports
- Focus on business value delivery and actionable insights
- Highlight critical issues requiring immediate attention
- Maintain traceability between requirements and implementation

## Related Skills

- `adf-plan` — Creates implementation plans (planning phase)
- `cook` — Implements plans (execution phase, invokes project-manager at finalize)
- `plans-kanban` — Visual dashboard for plan viewing
