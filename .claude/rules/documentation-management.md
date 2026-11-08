# Project Documentation Management

Use this file when creating plans, changing project documentation, or answering how much work something is or when it will be done.

## Layout

`docs/` is the project's living truth; `plans/` holds dated working artifacts. Test: when it stops being true, must someone fix it? Yes → `docs/`; no → `plans/`. `docs/README.md` is the map.

- `requirements/`: prd.md, srs.md, brd.md (optional), roadmap.md, usecases/{module}/
- `design/`: design-system/, mockups/{flow}/, wireframes/
- `architecture/`: system-architecture.md, codebase-summary.md, decisions/ (ADRs)
- `testing/`: testcases/{module}/, test-summary.md, test-config.md, exports/
- `conventions/`: code-standards.md, deployment.md, `<topic>.md`; each file has a front matter `description:` line and is listed at session start as an index, so read the ones that match the task
- `guides/`: user-facing guides
- Outside `docs/`: `CHANGELOG.md`, `assets/` (generated media), `plans/journals/`

Create a folder only when it has content. Project rules go in `docs/conventions/<topic>.md`.

## When To Update Docs

Update docs only when the change affects user-visible behavior, setup, commands, architecture, security posture, public contracts, or future maintainer decisions. Never edit `CHANGELOG.md` by hand on a feature branch: `git-flow.cjs changelog --write` writes it on the release branch.

Common docs:

- `docs/conventions/code-standards.md`
- `docs/architecture/system-architecture.md`
- `docs/requirements/roadmap.md`

## BA/QA Documentation

- **Software Requirements Specification (SRS)** (`./docs/requirements/srs.md`): feature specs, data models, business rules, API contracts, screen descriptions
- **Use Cases** (`./docs/requirements/usecases/{module}/`): per-module use case files (UC-{MOD}-{NNN})
- **Test Cases** (`./docs/testing/testcases/{module}/`): per-module test case files (TC-{MOD}-{NNN}-{NN})
- **Test Summary** (`./docs/testing/test-summary.md`): coverage matrix, priority/type distribution

Triggers:

- After BA analysis: update SRS and use cases via `/specs update`
- After QA generation: update test cases via `/test-cases update`

## Plan Location

Save plans under `plans/<timestamp>-<descriptive-slug>/`.

Use:

```text
plans/<slug>/
  plan.md
  phase-01-<name>.md
  reports/
```

Keep `plan.md` short: status, phases, dependencies, acceptance criteria, and links to phase files.

Phase files should include only the detail needed to execute safely:

- context links
- requirements
- files to modify/create/delete
- implementation steps
- tests or validation
- risks and rollback notes

Before updating docs, read the existing document. After updating, verify dates, links, and claims match the actual change.

## Estimates

When someone asks how much work something is or when it will be done, answer with `size` and `human_effort` (the hours a person spends clarifying, deciding, reviewing and testing) and the unknowns that could grow it. Take them from the plan when one exists. Do not convert those hours into working days, dates or a promise, and do not call them coding hours: agent run time is not the limit, and the team adds its own buffer and sets the date. Sizing rules: `.claude/skills/adf-plan/references/output-standards.md#estimates`.
