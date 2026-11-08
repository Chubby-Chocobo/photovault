# Documentation Management Routing

Use this file when another skill needs to decide whether docs should be created
or updated. For full doc operations, use `/docs init`, `/docs update`, or
`/docs summarize`.

## When To Update Docs

Update docs only when the change affects:

- user-visible behavior
- setup, install, or CLI commands
- architecture, data flow, or public contracts
- security posture or operational procedures
- future maintainer decisions that should not be rediscovered

Do not add documentation noise for purely internal edits unless the repo already
requires it.

## Common Docs

- `docs/requirements/prd.md`
- `docs/architecture/codebase-summary.md`
- `docs/conventions/code-standards.md`
- `docs/architecture/system-architecture.md`
- `docs/requirements/roadmap.md`

`CHANGELOG.md` is not edited by hand: `git-flow.cjs changelog --write` writes it on the release branch.

## Plan and Report Locations

Save plans under `plans/<timestamp>-<descriptive-slug>/`.

```text
plans/<slug>/
  plan.md
  phase-01-<name>.md
  reports/
  visuals/
```

Keep `plan.md` short: status, phases, dependencies, acceptance criteria, and
links to phase files. Put execution detail in phase files.

## Cross-Skill Handoffs

- `/cook` and `/fix`: invoke docs update during finalize only when docs
  are warranted by the criteria above.
- `/adf-plan`: read existing docs before creating architecture or phase plans.
- `/preview`: save generated visuals under the active plan's `visuals/`
  folder when possible, then link them from docs only if they remain useful.
- `/tech-graph`: use for publish-grade architecture diagrams before adding
  diagrams to docs.

Before updating a doc, read it first. After updating, verify dates, links, and
claims match the actual change.

