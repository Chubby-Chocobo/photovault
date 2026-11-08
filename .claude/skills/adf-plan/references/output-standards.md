# Output Standards & Quality

## Plan File Format

### YAML Frontmatter (Required for plan.md)

All `plan.md` files must include YAML frontmatter at the top:

```yaml
---
title: "{Brief plan title}"
description: "{One-sentence summary for card preview}"
status: pending  # pending | in-progress | completed | cancelled
priority: P2     # P1 (High) | P2 (Medium) | P3 (Low)
size: M          # S | M | L, the largest phase (see Estimates)
human_effort: 3-6h  # sum of phase ranges (see Estimates)
issue: 74        # GitHub issue number (if applicable)
branch: kai/feat/feature-name
tags: [frontend, api]  # Category tags
scope: [services/order, contracts/proto]  # monorepo or workspace only: paths this plan changes
blockedBy: []    # Plan dir names under ./plans/
blocks: []       # Example: [260228-0900-user-dashboard]
sources:         # external sources of the request (block list of "<role>: <type>:<locator>"); omit when none
  - "tracker: github-issue:acme/app#123"
authoritative: "tracker: github-issue:acme/app#123"  # the one source that wins when sources conflict; omit when none
created: 2025-12-16
---
```

`sources`, `authoritative`, each phase's `touches` and `acceptance`, and the `## Decisions` section of `plan.md` are specified in [plan-contract.md](./plan-contract.md); check them with `plan-phases.cjs --check <plan-dir>`.

When `--html` is active, `plan.html` is the primary artifact after validation
and audit gates. A companion `plan.md` may exist as a short index for
metadata, issue links, and cook handoff compatibility only. Do not duplicate
the full plan body in both files unless a downstream cook handoff needs
Markdown.

### Estimates

Estimate what an AI agent cannot shorten: the scope of the change and the time a person spends on it. Never estimate coding hours or calendar days; AI-assisted implementation makes them meaningless.

- `size` per phase, with a one-line reason in the phase Overview:
  - `S`: one module, a few files, a known pattern, no contract or schema change.
  - `M`: several files across one or two modules, or a change to a public contract, config or shared helper.
  - `L`: cross-module work, a migration or schema change, a public API change, a new dependency or unfamiliar technology, or security-sensitive code. Consider splitting an `L` phase.
- `human_effort` per phase: hours a person spends clarifying requirements, making decisions, reviewing diffs, testing by hand and approving. Exclude agent run time and waiting for CI or other people. Write a range such as `1-2h`.
- In `plan.md`, `size` is the largest phase size and `human_effort` sums the phase ranges.
- List the unknowns that could grow the effort in each phase's Risk Assessment. When the user asks for a deadline, give `human_effort` and those unknowns; the team adds its own buffer.

### HTML Plan Format (`--html`)

`plan.html` must be:
- Self-contained with inline CSS and JavaScript.
- Responsive and keyboard-accessible.
- Structured around overview, visible phase outlines, user flows, risks,
  diagrams, charts, citations, and open questions.
- Interactive where useful: tabs, expandable sections, filters, toggles, or
  chart controls.
- Source-cited with visible URL citations for external docs, GitHub issues,
  specs, and research links.
- Safe to open directly from disk without a dev server.
- Designed in editorial magazine style: warm paper `#faf7f2`, paper panels
  `#f0ebe1`, ink `#0a0a0a`, muted `#6b6258`, accent red `#b8232c`, serif
  display, mono labels, hairline dividers, asymmetric grids, rule lines, and
  subtle paper grain.
- Free of gradients, shadows, rounded cards, pure white backgrounds, emoji
  icons, generic SaaS styling, and decorative bokeh/orbs.
- Explicit on the main page: every phase shows title, status, priority,
  dependencies, objective, 3-6 key bullets, related files, success highlights,
  and test/validation gate when known.
- Modal-driven for detail: every phase outline opens a keyboard-accessible
  modal that renders full phase markdown with headings, lists, checkboxes,
  tables, code fences, inline code, blockquotes, links, horizontal rules, and
  frontmatter metadata.
- Illustrated when image generation is available: use `imagegen`,
  built-in `image_gen`, or `create_image` to generate 1-3 watercolor technical
  sketch assets, keep sources under `{plan-dir}/assets/`, and embed selected
  images as data URIs so `plan.html` remains portable.

### AgentWiki Publish Format (`--wiki`)

When `--wiki` is active:
- Publish only final reviewed artifacts after validation/audit gates.
- Use AgentWiki CLI when `agentwiki whoami` succeeds; otherwise use AgentWiki
  MCP document/upload/share/static-site tools when exposed.
- Markdown plans publish as AgentWiki documents. If details live across
  phase files, prepare `{plan-dir}/wiki-publish.md` as a concise combined
  document or index before upload.
- HTML plans publish through AgentWiki hosted static sites using the
  self-contained `plan.html`.
- Record returned document, share, publish, or site URLs in the final response.
  If `--github` is also active, add the wiki URL to the GitHub issue.
- If AgentWiki is unavailable or unauthenticated, skip publishing without
  failing plan creation and report the exact missing capability.
- Redact secrets, tokens, private logs, customer data, and local-only absolute
  paths before publishing.

### Auto-Population Rules

When creating plans, auto-populate these fields:
- **title**: Extract from task description
- **description**: First sentence of Overview section
- **status**: Always `pending` for new plans
- **priority**: From user request or default `P2`
- **issue**: Parse from branch name or context
- **branch**: Current git branch (`git branch --show-current`)
- **tags**: Infer from task keywords (e.g., frontend, backend, api, auth)
- **blockedBy**: Detected during pre-creation scan (empty `[]` if none)
- **blocks**: Detected during pre-creation scan (empty `[]` if none)
- **created**: Today's date in YYYY-MM-DD format
- **scope**: In a monorepo or workspace (session shows `Workspace:` or `Project: monorepo`), set `scope` to an inline list of paths, component names or contract ids, never a sentence: `scope: [services/order, contracts/proto]`. Run `node .claude/skills/workspace/scripts/workspace.cjs scope --paths <...> --json` and add the expanded consumers to `scope`, unless that passes 50 entries: then keep the contract id, which expands to its consumers by itself. After writing `plan.md`, run `workspace.cjs scope --plan <plan-dir>`. It exits 1 when an entry is not a path, component name or contract id (a sentence, say) or the list passes 50 entries; hooks ignore those entries too, so fix `scope` until it exits 0. An entry for a path that does not exist yet (a service the plan creates, a member not cloned) is reported, not an error: keep it. In a workspace, create the plan under the workspace `plans/` even when the scope is one member. Omit `scope` elsewhere.

### Plan Reference Syntax

- Reference plans by directory name under `./plans/`, e.g. `260301-1200-auth-system`.

Missing references should warn and render as `not found`. They should not block plan creation.

### Tag Vocabulary (Recommended)

Use these predefined tags for consistency:
- **Type**: `feature`, `bugfix`, `refactor`, `docs`, `infra`
- **Domain**: `frontend`, `backend`, `database`, `api`, `auth`
- **Scope**: `critical`, `tech-debt`, `experimental`

### Task Naming Conventions

**subject** (imperative): Action verb + deliverable, <60 chars
  Examples: "Setup database migrations", "Implement OAuth2 flow"

**activeForm** (continuous): Present participle of subject
  Examples: "Setting up database", "Implementing OAuth2"

**description**: 1-2 sentences, concrete deliverables, reference phase file

See `task-management.md` for full TaskCreate patterns and metadata.

## Task Breakdown

- Transform complex requirements into manageable, actionable tasks
- Each task independently executable with clear dependencies
- Prioritize by dependencies, risk, business value
- Eliminate ambiguity in instructions
- Include specific file paths for all modifications
- Provide clear acceptance criteria per task

### File Management

List affected files with:
- Full paths (not relative)
- Action type (modify/create/delete)
- Brief change description
- Dependencies on other changes
- Fully respect the `./docs/conventions/code-standards.md` file.

## Workflow Process

1. **Initial Analysis** → Read docs, understand context
2. **Research Phase** → Spawn researchers in parallel, investigate approaches
3. **Synthesis** → Analyze reports, identify optimal solution
4. **Design Phase** → Create architecture, implementation design
5. **Plan Documentation** → Write comprehensive plan in Markdown, or `plan.html`
   when `--html` is present
6. **Review & Refine** → Ensure completeness, clarity, actionability

## Output Requirements

### What Planners Do
- Create plans only (no implementation)
- Provide plan file path and summary
- With `--html`, provide the `plan.html` path first and say it is authoritative
- With `--wiki`, provide the AgentWiki document/share/site URL when published,
  or the exact skip reason when unavailable
- Self-contained plans with necessary context
- Code snippets/pseudocode when clarifying
- Multiple options with trade-offs when appropriate
- Fully respect the `./docs/conventions/code-standards.md` file.

### Writing Style
In reports, prefer brevity over full sentences
- Focus clarity over eloquence
- Use bullets and lists
- Short sentences
- Remove unnecessary words
- Prioritize actionable info

### Unresolved Questions
Use `AskUserQuestion` to ask users for unresolved questions at the end
- Questions needing clarification
- Technical decisions requiring input
- Unknowns impacting implementation
- Trade-offs requiring business decisions
Revise the plan and phases based on the answers.

## Quality Standards

### Thoroughness
- Thorough and specific in research/planning
- Consider edge cases, failure modes
- Think through entire user journey
- Document all assumptions

### Maintainability
- Consider long-term maintainability
- Design for future modifications
- Document decision rationale
- Avoid over-engineering
- Fully respect the `./docs/conventions/code-standards.md` file.

### Research Depth
- When uncertain, research more
- Multiple options with clear trade-offs
- Validate against best practices
- Consider industry standards

### Security & Performance
- Address all security concerns
- Identify performance implications
- Plan for scalability
- Consider resource constraints

### Implementability
- Detailed enough for junior developers
- Validate against existing patterns
- Ensure codebase standards consistency
- Provide clear examples

**Remember:** Plan quality determines implementation success. Be comprehensive, consider all solution aspects.
