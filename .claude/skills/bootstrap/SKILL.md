---
name: bootstrap
description: "Bootstraps a new project end to end: research, tech stack, design, planning, implementation (modes: full, auto, fast, parallel)."
user-invocable: true
when_to_use: "Invoke to start a new project from scratch."
category: utilities
keywords: [scaffold, project, setup, boilerplate]
license: MIT
argument-hint: "[requirements] [--full|--auto|--fast|--parallel]"
metadata:
  author: adf
  version: "1.0.0"
---

# Bootstrap - New Project Scaffolding

End-to-end project bootstrapping from idea to running code.

**Principles:** YAGNI, KISS, DRY | Token efficiency | Concise reports

## Usage

```
/bootstrap <user-requirements>
```

**Flags** (optional, default `--full`):

| Flag | Mode | Thinking | User Gates | Planning Skill | Cook Skill |
|------|------|----------|------------|----------------|------------|
| `--full` | Full interactive | Ultrathink | Every phase | `--hard` | (interactive) |
| `--auto` | Automatic explicit opt-in | Ultrathink | Design only | `--auto` | `--auto` |
| `--fast` | Quick | Think hard | Cook review gates | `--fast` | (interactive) |
| `--parallel` | Multi-agent | Ultrathink | Design only | `--parallel` | `--parallel` |

**Example:**
```
/bootstrap "Build a SaaS dashboard with auth" --fast
/bootstrap "E-commerce platform with Stripe" --parallel
```

## Workflow Overview

```
[Git Init] → [Research?] → [Tech Stack?] → [Design?] → [Planning] → [Implementation] → [Test] → [Review] → [Docs] → [Onboard] → [Final]
```

Each mode loads a specific workflow reference + shared phases.

## Mode Detection

If no flag provided, default to `--full`.

Load the appropriate workflow reference:
- `--full`: Load `references/workflow-full.md`
- `--auto`: Load `references/workflow-auto.md` only when explicitly requested
- `--fast`: Load `references/workflow-fast.md`
- `--parallel`: Load `references/workflow-parallel.md`

All modes share: Load `references/shared-phases.md` for implementation through final report.

## Step 0: Git Init (ALL modes)

Check if Git initialized. If not:
- `--full`: Ask user if they want to init → `git-manager` subagent (`main` branch)
- Others: Auto-init via `git-manager` subagent (`main` branch)

## Skill Triggers

After early phases (research, tech stack, design), trigger downstream skills:

### Planning Phase
Activate **adf-plan** skill with mode-appropriate flag:
- `--full` → `/adf-plan --hard <requirements>` (thorough research + validation)
- `--auto` → `/adf-plan --auto <requirements>` (auto-detect complexity)
- `--fast` → `/adf-plan --fast <requirements>` (skip research)
- `--parallel` → `/adf-plan --parallel <requirements>` (file ownership + dependency graph)

Planning skill outputs a plan path. Pass this to cook.

### Implementation Phase
Activate **cook** skill with the plan path and mode-appropriate flag:
- `--full` → `/cook <plan-path>` (interactive review gates)
- `--auto` → `/cook --auto <plan-path>` (explicit autonomous implementation)
- `--fast` → `/cook <plan-path>` (skip extra research, keep cook review gates)
- `--parallel` → `/cook --parallel <plan-path>` (multi-agent execution)

## Role

Elite software engineering expert specializing in system architecture and technical decisions. Brutally honest about feasibility and trade-offs.

## Critical Rules

- Activate relevant skills from catalog during the process
- Keep all research reports ≤150 lines
- All docs written to `./docs` directory
- Plans written to `./plans` directory using naming from `## Naming` section
- Do not implement code directly — delegate through planning + cook skills
- In reports, prefer brevity over full sentences in reports
- List unresolved questions at end of reports
- Run `/journal` only when the user asks or the work hit a notable setback.

## References

- `references/workflow-full.md` - Full interactive workflow
- `references/workflow-auto.md` - Explicit auto workflow
- `references/workflow-fast.md` - Fast workflow
- `references/workflow-parallel.md` - Parallel workflow
- `references/shared-phases.md` - Common phases (implementation → final report)
