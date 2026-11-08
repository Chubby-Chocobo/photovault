# Skill Pipelines

Use this reference to chain skills around GitHub as the handoff ledger.

## Intake To Plan

```text
ghpm -> scout -> research -> adf-plan
```

1. `ghpm`: create or update issue with outcome, constraints, labels, project fields.
2. `scout`: locate repo files and risks; comment findings back to issue.
3. `research`: research unstable APIs or external dependencies; attach report link.
4. `adf-plan`: create implementation plan; link plan path in issue.

## Plan To Code

```text
ghpm -> cook -> test -> adf-code-review -> git
```

1. Move issue/project status to In Progress.
2. `cook`: implement scoped work.
3. `test`: run test suite; comment evidence.
4. `adf-code-review`: review changed code; create follow-up issues for non-blocking items.
5. `git cp`: commit/push branch; link commit to issue.

## Bugfix

```text
ghpm -> adf-debug -> fix -> test -> review-pr --fix
```

Use when GitHub issue/CI/PR reports breakage. Keep the root cause, failing command, and fixed verification in the issue comments.

## Release

```text
ghpm -> ship beta|official -> review-pr --fix --reply -> ghpm
```

1. Ensure issue has release scope and acceptance criteria.
2. Run ship mode requested by user.
3. Review PR and fix actionable findings.
4. Add final issue comment with PR URL, checks, remaining follow-ups.

## Human Handoff

```text
ghpm -> adf-brief -> project-management
```

Use when another human or session needs continuation:

- `adf-brief`: summarize branch/worktree/unfinished work.
- `project-management`: reconcile local plan status if plans exist.
- `ghpm`: write canonical handoff comment and update Project `Next Action`.

## Automation Ideas

- Auto-label new issues with `status:triage`.
- Move issue to Ready when required fields/checklist exist.
- Mark Blocked when label `agent:human-needed` appears.
- Comment on stale In Progress items with last PR/check evidence.
- Generate weekly status issue from project items and CI runs.
- Open follow-up issue when PR review marks deferred work.
