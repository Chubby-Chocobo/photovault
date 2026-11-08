# Workflow Routing

Use this file when choosing the sequence for multi-step work. It is a routing
map only; load the owning `SKILL.md` before executing details.

## Core Sequences

| User intent | Sequence |
|---|---|
| Implement a feature | `/adf-plan` -> `/cook` -> `/test` -> `/adf-code-review` |
| Execute an existing plan | `/cook <plan-path>` |
| Quick implementation | `/cook --fast` |
| Bug, error, failed test, or CI failure | `/fix` |
| Investigate before deciding | `/scout` -> `/adf-debug` -> `/brainstorm-technical` -> `/adf-plan` |
| Review a GitHub PR | `/review-pr <PR>` |
| Review a diff, commits or local changes | `/adf-code-review` |
| Fix review feedback | `/review-pr <PR> --fix` or `/fix --parallel` |
| Ship a completed branch | `/ship` |
| Explain work visually | `/preview --explain` or `/preview --html --diff` |
| Update project docs | `/docs update` |

## Implementation Owner

- Use `/cook` for known feature scope after requirements are clear.
- Use `/fix` for concrete bugs, errors, test failures, and CI failures.
- Use `/adf-plan` when work needs architecture, phases, file ownership, or TDD
  structure.
- Use `/test` for verification-only work.
- Use `/ship` only after implementation, tests, and review are done.

## Handoff Rules

- Domain skill first, workflow skill second. Example: for a React feature,
  route to `/frontend-development`, then execute through `/adf-plan` and
  `/cook` if implementation is needed.
- For visual explanations, load
  `../../preview/references/visual-explanation-routing.md`.
- For documentation changes, load
  `../../docs/references/documentation-management.md` or invoke
  `/docs update`.
- For ambiguous skill choice, use the intent table in `skill-routing.md`; if
  no row fits, pick the skill whose `when_to_use` matches the request.

## Post-Implementation

- Review high-risk, cross-module, or public-contract changes before shipping.
- Update docs only when behavior, setup, commands, architecture, security
  posture, public contracts, or future maintainer decisions changed.
- Journal only when the user asks or the work hit a notable setback.
