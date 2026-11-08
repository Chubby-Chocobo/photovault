# Plan Creation & Organization

## Directory Structure

### Plan Location

Use `Plan dir:` from `## Naming` section injected by hooks. This is the full computed path.

Plans live under the project `./plans/`, e.g. `plans/251101-1505-authentication/`.

### File Organization

In the active scope root:
```
{plan-dir}/                                    # From `Plan dir:` in ## Naming
├── research/
│   ├── researcher-XX-report.md
│   └── ...
├── reports/
│   ├── scout-report.md
│   ├── researcher-report.md
│   └── ...
├── assets/                                    # Generated image sources for plan.html
├── plan.md                                    # Overview access point
├── plan.html                                  # Primary artifact when --html is used
├── wiki-publish.md                            # Optional combined doc when --wiki publishes Markdown
├── phase-01-setup-environment.md              # Setup environment
├── phase-02-implement-database.md             # Database models
├── phase-03-implement-api-endpoints.md        # API endpoints
├── phase-04-implement-ui-components.md        # UI components
├── phase-05-implement-authentication.md       # Auth & authorization
├── phase-06-implement-profile.md              # Profile page
└── phase-07-write-tests.md                    # Tests
```

### Task Hydration

After creating plan.md and phase files, hydrate tasks (unless `--no-tasks`).
When `--html` is present, hydrate tasks only from the companion `plan.md`
index if it contains actionable checkboxes; otherwise skip hydration and state
that `plan.html` is the authoritative artifact.
1. TaskCreate per phase with `addBlockedBy` dependency chain
2. Add critical step tasks for high-risk items
3. See `task-management.md` for patterns and cook handoff protocol

### HTML Artifact Layout

When `--html` is present:
- Keep `plan.html` as the primary user-facing artifact.
- Keep `plan.md` as a concise index for metadata, GitHub links, and cook handoff
  compatibility when needed.
- Keep every `phase-*.md` as the detailed implementation contract when Markdown
  phase files are generated.
- Put generated image source files under `assets/`, then embed selected images
  in `plan.html` as data URIs.
- Verify the main page exposes every phase outline and that each outline opens
  a rendered markdown detail modal.
- Verify `plan.html` opens as a portable single file with no missing local asset
  paths.

### AgentWiki Publish Layout

When `--wiki` is present:
- Publish after final plan gates and after `plan.html` exists when `--html`
  is also present.
- For Markdown output, publish `plan.md` when it is complete enough to stand
  alone. If phase details are split across files, create `wiki-publish.md` as
  a concise combined document or index before publishing.
- For HTML output, publish the portable `plan.html` through AgentWiki hosted
  static sites.
- Record returned AgentWiki document/share/site URLs in `plan.md` when a
  companion Markdown index exists. If `--github` is active, add the URL to the
  GitHub issue.
- Do not publish secrets, raw logs, private env values, or local-only absolute
  paths.

### Active Plan State Tracking

See SKILL.md "Active Plan State" section for full rules. Key points:
- Check `## Plan Context` injected by hooks for active/suggested/none state
- After creating plan: `node .claude/scripts/set-active-plan.cjs {plan-dir}`
- Active plans use plan-specific reports path; suggested plans use default path

## Plan Creation

After determining phases from research/design:

1. **Create the plan directory** using the `Plan dir:` from `## Naming` and write `plan.md` plus one `phase-XX-*.md` per phase (planner subagent).

2. **Fill content sections** in plan.md:
   - `## Overview` — brief description
   - `## Dependencies` — cross-plan dependencies

3. **Fill each phase-XX.md** with:
   - Architecture, implementation steps, success criteria
   - Requirements, risk assessment, security considerations

4. **Keep the Phases table in plan.md in sync** with phase files when status or structure changes (edit directly).

5. **If `--html`, generate `plan.html` after final plan gates:**
   - Re-read `plan.md` and every `phase-*.md` that exists.
   - Extract visible phase outline summaries for the main page.
   - Render full phase markdown into click-open detail modals.
   - Embed generated watercolor technical sketch images when available.
   - Verify `plan.html` opens without missing local assets.
6. **If `--wiki`, publish final artifacts after gates:**
   - Use `agentwiki doc upload`/`doc publish`/`doc share` for Markdown docs.
   - Use `agentwiki sites upload` for `plan.html`.
   - Use AgentWiki MCP only when equivalent document/share/site capabilities
     are exposed in the active session.
   - Capture and report the returned URL, or report the exact skip reason.

In `--html` mode, write the primary `plan.html` after planning gates finish so
the HTML reflects the reviewed plan. If `--github` is also present, keep a
concise Markdown `plan.md` index for the requested repo-relative link.

## File Structure

### Overview Plan (plan.md)

All plan.md files must include YAML frontmatter. See `output-standards.md` for schema.
When `--html` is active, `plan.md` may be a concise index instead of the full
plan body. It should link to `plan.html`, summarize phases, and keep GitHub
issue metadata stable.

**Example plan.md structure:**
```markdown
---
title: "Feature Implementation Plan"
description: "Add user authentication with OAuth2 support"
status: pending
priority: P1
size: L
human_effort: 6-10h
issue: 123
branch: kai/feat/oauth-auth
tags: [auth, backend, security]
scope: [services/order, contracts/proto]  # monorepo or workspace only: paths, components or contract ids this plan changes, never prose
blockedBy: []
blocks: [260115-0900-user-dashboard]
sources:
  - "tracker: github-issue:acme/app#123"
authoritative: "tracker: github-issue:acme/app#123"
created: 2025-12-16
---

# Feature Implementation Plan

## Overview

Brief description of what this plan accomplishes.

## Cross-Plan Dependencies

| Relationship | Plan | Status |
|-------------|------|--------|
| Blocks | `260115-0900-user-dashboard` | pending |

## Phases

| Phase | Name | Status |
|-------|------|--------|
| 1 | [Setup Environment](./phase-01-setup.md) | Pending |
| 2 | [Core Implementation](./phase-02-impl.md) | Pending |
| 3 | [Testing & Validation](./phase-03-test.md) | Pending |

<!-- Link text must be human-readable names (not filenames).
     Bad:  [phase-01-setup.md](./phase-01-setup.md)
     Good: [Setup Environment](./phase-01-setup.md) -->

## Dependencies

- List key dependencies here

## Decisions

### Session store
- Chosen: in-process LRU
- Alternatives: Redis; no cache
- Why: the issue asks for no new infrastructure
- Review later: yes
```

A phase file carries `touches` and `acceptance` in its front matter (field rules in [plan-contract.md](./plan-contract.md)):

```yaml
---
phase: 1
title: "Setup Environment"
status: pending
dependencies: []
touches:
  - src/auth/**
  - test/auth/**
acceptance:
  - npm test
  - npm run lint
---
```

Reference rules:
- Reference plans by directory name under `./plans/`.

**Guidelines:**
- Keep generic and under 80 lines
- List each phase with status/progress
- Link to detailed phase files
- Key dependencies

### Phase Files (phase-XX-name.md)
Fully respect the `./docs/conventions/code-standards.md` file.
Each phase file should contain:

**Context Links**
- Links to related reports, files, documentation

**Overview**
- Priority
- Current status
- Brief description

**Key Insights**
- Important findings from research
- Critical considerations

**Requirements**
- Functional requirements
- Non-functional requirements

**Architecture**
- System design
- Component interactions
- Data flow

**Related Code Files**
- List of files to modify
- List of files to create
- List of files to delete

**Implementation Steps**
- Detailed, numbered steps
- Specific instructions

**Todo List**
- Checkbox list for tracking

**Success Criteria**
- Definition of done
- Validation methods

**Risk Assessment**
- Potential issues
- Mitigation strategies

**Security Considerations**
- Auth/authorization
- Data protection

**Next Steps**
- Dependencies
- Follow-up tasks

### Deep / TDD Extensions

When `--deep` is used, add:
- a file inventory table with action, rough size, and test impact
- a test scenario matrix for critical, high, and medium paths
- a dependency map that calls out links to other phases

When `--tdd` is used, add:
- a **Tests Before** section for regression coverage written first
- a **Refactor** section describing the protected code changes
- a **Tests After** section for new behavior introduced in that phase
- a regression gate listing the compile/test command that must pass
