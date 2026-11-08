# Primary Workflow

Use this file when a task needs an implementation workflow beyond a direct answer.

## 0. Requirements Analysis (Optional)

For projects that need formal requirements documentation:

- `/specs init`: create initial SRS + use cases from codebase and PRD
- `/specs analyze "feature"`: document new feature requirements
- `/specs update`: sync SRS and use cases with code changes
- `/test-cases generate`: generate test cases from use cases
- `/test-cases export csv`: export for manual QA testing

Skip this step if the project does not need formal BA/QA documentation.

## 1. Understand

- Read the request, relevant docs, and nearby code before planning.
- Clarify only decisions that cannot be discovered from the repo.
- For broad or risky work, create or update a plan in `plans/`.
- For ambiguous workflow sequence, load `.claude/skills/cook/references/workflow-routing.md`; for ambiguous skill choice, `.claude/skills/cook/references/skill-routing.md`.

## 2. Implement

- Change existing files when that matches the design; create new files only for real boundaries.
- Keep behavior compatible unless the accepted scope says otherwise.
- Prefer local helpers, conventions, and test utilities over new abstractions.
- For bugs, prove the cause before changing behavior.

## 3. Verify

- Run focused tests for touched behavior.
- Broaden to lint, typecheck, build, or integration tests when shared contracts changed.
- Fix regressions instead of weakening tests.

## 4. Review and Explain

- Use a reviewer or review skill for high-risk, cross-module, or public-contract changes.
- Update docs only when user-facing behavior, workflows, commands, or architecture changed.
- Explain the result plainly; use `/preview` only for complex workflows or architecture. For mode selection, load `.claude/skills/preview/references/visual-explanation-routing.md`.

## ADF Delegation

Small, focused changes need no subagents: test and review inline. When the work is substantial (multi-file, cross-module, risky), delegate in this order:

- After implementation, `tester` runs tests. Fix failures and repeat until green.
- Then `code-reviewer` reviews the tested code.
- Then, only if user-visible behavior or architecture changed, `docs-manager` updates `./docs`; if a plan exists, `project-manager` syncs its status.
- `git-manager` commits only when the user asks (see cook).
- For non-obvious bugs or CI failures, `debugger` diagnoses first, then fix and re-run `tester`.
