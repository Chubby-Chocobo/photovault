---
name: docs
description: "Analyze codebase and manage project documentation. Use for doc initialization, updates, summaries, codebase analysis."
user-invocable: true
when_to_use: "Invoke to create, refresh, or audit project documentation."
category: utilities
keywords: [documentation, init, update, summarize, migrate]
argument-hint: "init|update|summarize|migrate"
metadata:
  author: adf
  version: "1.2.0"
---

# Documentation Management

Analyze codebase and manage project documentation through scouting, analysis, and structured doc generation.

Invoke "/project-organization" skill to organize the outputs.

## Default (No Arguments)

If invoked without arguments, use `AskUserQuestion` to present available documentation operations:

| Operation | Description |
|-----------|-------------|
| `init` | Analyze codebase & create initial docs |
| `update` | Analyze changes & update docs |
| `summarize` | Quick codebase summary |
| `migrate` | Move legacy docs into the current layout |

Present as options via `AskUserQuestion` with header "Documentation Operation", question "What would you like to do?".

## Subcommands

| Subcommand | Reference | Purpose |
|------------|-----------|---------|
| `/docs init` | `references/init-workflow.md` | Analyze codebase and create initial documentation |
| `/docs update` | `references/update-workflow.md` | Analyze codebase and update existing documentation |
| `/docs summarize` | `references/summarize-workflow.md` | Quick analysis and update of codebase summary |
| `/docs migrate` | (below) | Move a legacy docs layout into the current one |

When another workflow needs to decide whether docs should change, load
`references/documentation-management.md` before invoking a docs update.

## Routing

Parse `$ARGUMENTS` first word:
- `init` → Load `references/init-workflow.md`
- `update` → Load `references/update-workflow.md`
- `summarize` → Load `references/summarize-workflow.md`
- `migrate` → Run the migrate steps below
- empty/unclear → AskUserQuestion (do not auto-run `init`)

## Migrate

For projects whose docs predate the current layout:

1. Run `node .claude/skills/docs/scripts/migrate-docs-layout.cjs --dry-run` and show the planned moves and link rewrites.
2. Ask the user (`AskUserQuestion`) whether to apply them.
3. On approval, run the same command without `--dry-run`, then report what moved.

Options (pass the same ones to the dry run and the real run):
- `--include-rules` also moves `.claude/rules/project-*.md` into `docs/conventions/`. They then stop loading in every session and are listed as conventions instead; ask before using it, and suggest keeping always-on rules in the root `CLAUDE.md`.
- `--allow-dirty` runs even with uncommitted changes in files it would move or edit.
- `--allow-no-git` runs outside a git work tree; `--allow-doc-site` runs when `docs/` is a documentation site (better: set `paths.docs` to another folder).

The script checks every move before the first one and undoes the moves if one fails. Never move files without the user's approval.

## Shared Context

Documentation lives in `./docs` directory:
```
./docs
├── README.md                 # Map of the docs
├── requirements/             # prd.md, srs.md, roadmap.md, usecases/
├── design/                   # design-system/, mockups/, wireframes/
├── architecture/             # system-architecture.md, codebase-summary.md, system-map.json, services/<name>.md, decisions/
├── testing/                  # testcases/, test-summary.md, exports/
├── conventions/              # code-standards.md, deployment.md, <topic>.md
└── guides/                   # User-facing guides
```

Use the docs directory as the source of truth for documentation. `docs/` in this skill and its references means the Docs path from session context (`paths.docs`, also `$ADF_DOCS_PATH`); use that path in every write, `find` and `validate-docs` command when it is not `docs`.

When authoring or refreshing diagrams in `architecture/system-architecture.md`, apply the universal SVG layout rules from `/tech-graph` at `.claude/skills/tech-graph/references/svg-layout-best-practices.md` (component spacing, arrow routing, label placement, z-index ordering). Pair with `/preview --diagram` for visual self-review, or use `/tech-graph` directly for publish-grade output.

**Do not** start implementing code.
