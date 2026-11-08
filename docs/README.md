<!-- adf-template: .claude/templates/docs/README.md@d51543c943ac1fe5 -->
# Project docs

This folder is the project's living truth. When something here stops being true, fix it in the same change that made it untrue. Dated working material (plans, agent reports, research, journals) goes in `plans/` instead.

**Start here:** `AGENTS.md` at the repo root (ADF's rules for every agent), then [agent-rules.md](conventions/agent-rules.md) (this project's own agent rules) and `conventions/git-workflow.md` when the project has one (branches, commits and pull requests).

**Where does a file go?** Ask "When this stops being true, must someone fix it?" If yes, it belongs here. If no, because it records a moment, it belongs in `plans/`.

## Folders

Create a folder only when it has content. Each one answers one question and has one owner.

| Folder | Answers | Owner | Typical files | Written by |
|---|---|---|---|---|
| `requirements/` | What do we build, for whom, and why? | BA / PO | `prd.md`, `srs.md`, `brd.md` (optional), `roadmap.md`, `usecases/{module}/` | `/specs`, `business-analyst` |
| `design/` | What does the user see and do? | UI/UX | `design-system/`, `mockups/{flow}/`, `wireframes/` | `/design-system`, `/design-mockup-create`, `ui-ux-designer` |
| `architecture/` | How is it built? | Tech lead | `system-architecture.md`, `codebase-summary.md` | `/docs`, `docs-manager`, `planner` |
| `decisions/` | Why is it built this way, and what would reopen it? | Tech lead | `README.md` (index), `0001-….md` … (one per decision) | the agent that makes the decision |
| `spikes/` | What must the owner measure before a default is trusted? | Owner | `README.md` (index), `m0-*.md` (procedure and results) | `docs-manager`; results filled in by the owner |
| `testing/` | How do we know it works? | QA | `testcases/{module}/`, `test-summary.md`, `exports/` | `/test-cases`, `testcase-writer` |
| `conventions/` | How do the team and its agents work? | Whole team | `code-standards.md`, `git-workflow.md`, `deployment.md`, one file per topic | the team; `/docs` starts `code-standards.md` |
| `guides/` | How do users of the product use it? | Docs owner | setup guides, user manuals, API usage | `docs-manager` |

## Project files

PhotoVault keeps these at the paths its spec names (see [decision 0005](decisions/0005-docs-paths.md)):

| File | Answers |
|---|---|
| [requirements/photovault-spec-v1.md](requirements/photovault-spec-v1.md) | What the app must do: the FR, NFR and T codes used everywhere else |
| [sidecar-schema.md](sidecar-schema.md) | What the JSON and XMP sidecars contain, and how they are written |
| [decisions/](decisions/README.md) | Why the code is built the way it is |
| [spikes/](spikes/README.md) | The M0 measurements the owner runs before defaults are final |
| [design/](design/README.md) | The screens, as interactive mockups |

## Cases that look ambiguous

| Content | Goes in | Why |
|---|---|---|
| Non-functional requirements (performance, security, availability) | `requirements/srs.md` | they are requirements to meet |
| API contract, data model | `architecture/` | technical design; the SRS only says what data the system must provide |
| A decision and its trade-offs | `decisions/` (this project; ADF's default is `architecture/decisions/`, see [decision 0005](decisions/0005-docs-paths.md)) | stays true until superseded by a newer decision |
| Deploy steps, incident runbooks | `conventions/` | how the team operates |
| Design tokens, component catalog | `design/design-system/` | |
| Release notes | `CHANGELOG.md` at the repo root | |
| Images, videos, generated media | `assets/` at the repo root | binary files are not docs |

## Conventions and agents

Each file in `conventions/` starts with front matter that has a one-line `description`:

```markdown
---
description: Branch model, merge rules and release steps for this repo
---
```

An agent picks the file that fits its task by its `description` and reads the whole file then. Claude Code gets the list of descriptions at session start; other agents are pointed here by `AGENTS.md`. Keep each file focused on one topic, so the list stays useful and each read stays small.

Project-specific rules for agents belong here too, for example `conventions/database-migrations.md`.

## Ownership

- Everything in this folder belongs to the project. ADF never overwrites it.
- Files that ADF seeded, such as this README, carry an `adf-template` stamp. When ADF's template changes, the installer tells you which file to compare, and you decide what to copy.
- Delete the stamp line if you no longer want those notices.
- The one exception to "never overwrites": the installer rewrites the text between the `adf:git-settings` markers in `conventions/git-workflow.md` from your `git` config, every time it runs, unless you edited that text. Edit it and the installer leaves it alone and says so; empty it and the installer fills it again.
