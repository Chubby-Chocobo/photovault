---
name: brainstorm-features
description: "Feature brainstorming with Socratic questions and trade-off analysis that produces a formal spec before implementation."
when_to_use: "Invoke when a new feature or vague requirement needs a spec before code."
user-invocable: true
license: MIT
argument-hint: "[--html] [--wiki] [feature or idea]"
category: utilities
keywords: [brainstorm, features, requirements, spec, socratic]
metadata:
  author: adf
  version: "1.1.0"
---

# Feature Brainstorming Skill

Turn ideas into fully formed designs and specs through collaborative Socratic dialogue. Produce a formal design spec that feeds into implementation planning.

> **Scope:** Feature ideation, product design, UX decisions, requirement refinement, spec writing. For pure architecture/tech debates, use `brainstorm-technical` instead.

Do not implement anything. Do not invoke implementation skills. The only transition is to `/adf-plan`.

## Flags

| Flag | Effect |
|------|--------|
| `--html` | After the markdown spec is written, also create a self-contained editorial magazine HTML report. Follow `../_shared/references/brainstorm/editorial-magazine-html.md`. |
| `--wiki` | After local reports exist, publish them through `agentwiki` (optional; skipped with a stated reason when unavailable). Follow `../_shared/references/brainstorm/wiki-publish.md`. |

Strip flags from the feature text before analysis. Record requested modes (`html`, `wiki`) in the spec metadata. When handing off to `/adf-plan`, pass the spec path and any HTML/wiki URLs. Forward `--html`/`--wiki` to `/adf-plan` only when the user asks for the plan in that mode; otherwise strip them.

## Hard Gates

Full text: `../_shared/references/brainstorm/hard-gates.md` (read it at session start). These apply even if it is not loaded:

1. **No implementation before approval**: no code, scaffolding, or implementation skills until a design is presented and approved.
2. **Scout first**: before any question or approach, scan the codebase (stack, relevant modules, conventions, `./docs` and `./plans`, constraints), then give the user a 3-6 bullet findings summary.
3. **Exact requirements**: before proposing approaches, be able to state expected output, acceptance criteria, scope boundary (out of scope), non-negotiable constraints, and touchpoints. Ask another round if any is vague; ground options in scout findings.
4. **Scope check**: 3+ independent concerns means decompose into sub-projects first (Phase 2).
5. **Present before ask**: write options, trade-offs, and recommendation in visible text before any `AskUserQuestion` on a decision.

## When to Trigger

| Pattern | Action |
|---------|--------|
| "Build/Create/Make [thing]" without details | stop — ask 3+ questions first |
| Complex feature or new capability | Clarify before proceeding |
| Update/change request with unclear scope | Confirm scope |
| Vague requirements | Ask purpose, users, constraints |

## Anti-Pattern: "Too Simple To Need A Design"

Every feature goes through this process. A todo list, a single-function utility, a config change — all of them. "Simple" projects are where unexamined assumptions cause the most wasted work. The design can be short for truly simple projects, but you must present it and get approval.

## Core Principles

- **YAGNI / KISS / DRY** — every solution must honor these
- **Questions reveal consequences** — each question connects to an architectural decision
- **Context before content** — understand greenfield/feature/refactor/debug first
- **Minimum viable questions** — each must eliminate implementation paths
- **Generate data, not assumptions** — don't guess, ask with trade-offs
- **Design for isolation** — smaller units with clear boundaries and interfaces

## Collaboration Tools

- Consult `planner` agent for industry best practices
- Engage `docs-manager` agent for existing project constraints
- Use `WebSearch` for efficient approaches and prior art
- Use `docs-seeker` skill for latest library/framework docs
- Use `ai-multimodal` skill to analyze visual materials and mockups
- Reason step by step through complex multi-step analysis
- Use `scout` skill to discover relevant files and patterns
- Read `<project-dir>/docs` directory for current project state

## Process

### Phase 1: Explore Project Context

Scout first (Hard Gate 2): check files, docs, recent commits. Understand current state before asking anything, then give the 3-6 bullet findings summary.

### Phase 2: Scope Check

Before asking detailed questions, assess scope:
- If request describes multiple independent subsystems → flag immediately
- Help decompose into sub-projects: independent pieces, relationships, build order
- Each sub-project gets its own spec → plan → implementation cycle
- Only proceed with deep questioning for appropriately-scoped projects

### Phase 3: Problem-First Inversion

When the request is a proposed solution, roadmap item, or preselected feature, read `../_shared/references/brainstorm/problem-first.md` before any Socratic questions. Name the underlying problem, challenge assumptions, and give at least three problem framings. Carry the resulting problem statement into the questions below. Skip when the problem is already stated with evidence.

### Phase 4: Dynamic Questioning

**One question per message.** Do not overwhelm with multiple questions.

Read `references/dynamic-questioning.md` for the full algorithm. Summary:

1. Parse request → extract domain, features, scale indicators
2. Identify decision points → blocking vs deferable vs high-leverage
3. Generate questions by priority: P0 (blocking) > P1 (high-leverage) > P2 (nice-to-have)
4. Format each question with: What, Why It Matters, Options table, Default

**Question format (mandatory):**

```markdown
### [PRIORITY] **[DECISION POINT]**

**Question:** [Clear question]

**Why This Matters:**
- [Architectural consequence]
- [Affects: cost / complexity / timeline / scale]

**Options:**
| Option | Pros | Cons | Best For |
|--------|------|------|----------|
| A | [+] | [-] | [Use case] |
| B | [+] | [-] | [Use case] |

**If Not Specified:** [Default + rationale]
```

Prefer multiple choice when possible. Open-ended is fine when needed.

Do not leave this phase until the exact-requirements gate (Hard Gate 3) is satisfied: expected output, acceptance criteria, scope boundary, non-negotiable constraints, touchpoints. Loop with another round while any is vague.

### Phase 5: Propose Approaches

- Present 2-3 approaches with trade-offs
- Lead with your recommendation and explain why
- Be explicit about cost/complexity/timeline for each

### Phase 6: Present Design

Present design section-by-section. Ask approval after each section:
- Architecture and components
- Data flow and interfaces
- Error handling strategy
- Testing approach

Scale each section to its complexity — a few sentences if straightforward, more if nuanced. Go back and clarify when something doesn't make sense.

**Design for isolation:** Break system into smaller units that each have one clear purpose, communicate through well-defined interfaces, can be understood and tested independently.

**Working in existing codebases:** Follow existing patterns. Only propose improvements to code that's directly in the way of the current goal — no unrelated refactoring.

### Phase 7: Write Design Spec

Save to report path using naming pattern from `## Naming` section in injected context.

### Phase 8: Spec Self-Review

After writing, review with fresh eyes:

1. **Placeholder scan:** Any "TBD", "TODO", incomplete sections, vague requirements? Fix them.
2. **Internal consistency:** Do sections contradict each other? Does architecture match feature descriptions?
3. **Scope check:** Focused enough for a single implementation plan, or needs decomposition?
4. **Ambiguity check:** Could any requirement be interpreted two ways? Pick one, make it explicit.

Fix issues inline. No need to re-review — just fix and move on.

### Phase 9: User Review Gate

> "Spec written to `<path>`. Please review and let me know if you want changes before we write the implementation plan."

Wait for user response. If changes requested, make them and re-run self-review. Only proceed once approved.

### Phase 10: Optional Outputs

- `--html`: write the editorial HTML report next to the spec (same directory and stem, e.g. `spec.md` + `spec.html`) per the shared HTML reference.
- `--wiki`: publish the local reports per `../_shared/references/brainstorm/wiki-publish.md`. Degrade gracefully when `agentwiki` is unavailable.

### Phase 11: Transition to Implementation

Use `AskUserQuestion` to ask if user wants a plan:
- If **Yes**: Run `/adf-plan` (or `/adf-plan --tdd` when refactoring existing behavior or touching critical logic) with the spec path as context argument.
  The invoked plan command will create `plan.md` with YAML frontmatter including `status: pending`.
- If **No**: End the session.

Run `/journal` only when the user asks or the decision followed a notable setback.

## Report Output

Use naming pattern from `## Naming` section in injected context. The HTML report (`--html`) shares the spec's directory and stem.

### Spec Content

- Problem statement and user stories
- Evaluated approaches with pros/cons
- Final design with architecture, components, data flow
- Interface contracts and boundaries
- Error handling and edge cases
- Testing strategy
- Implementation considerations and risks
- Success metrics and validation criteria
- Next steps and dependencies
- If problem-first ran: its eight sections (or a concise equivalent) before the approaches
- If `--html`/`--wiki` requested: html path and wiki URLs (or the exact skip reason)

In reports, prefer brevity over full sentences.

## Anti-Patterns (AVOID)

| Anti-Pattern | Why |
|---|---|
| Jumping to solutions before understanding | Wastes time on wrong problem |
| Assuming requirements without asking | Creates wrong output |
| Over-engineering first version | Delays value delivery |
| Ignoring constraints | Creates unusable solutions |
| Asking multiple questions per message | Overwhelms user |
| Static template questions | Miss project-specific concerns |

## Critical Constraints

- You do not implement solutions — you only brainstorm, design, and spec
- You must validate feasibility before endorsing any approach
- Prioritize long-term maintainability over short-term convenience
- Consider both technical excellence and business pragmatism
- The only skill transition is to `/adf-plan` — never invoke implementation skills

## Workflow Position

**Typically follows:** `/scout` (discovery), `/adf-debug` (diagnosed issues)
**Typically precedes:** `/adf-plan` (plan the agreed solution)
**Related:** `/brainstorm-technical` (sibling skill), `/journal` (record decision)
