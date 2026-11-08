---
name: ship
description: "Ship pipeline for a feature, fix or hotfix branch: merge target, test, review, docs, optional journal and AgentWiki publish, commit, push, PR against the git workflow's target. Use when a branch is ready for review."
user-invocable: true
when_to_use: "Invoke when a completed branch needs PR shipping workflow."
category: dev-tools
keywords: [ship, PR, merge, push, release]
argument-hint: "[official|beta] [--skip-tests] [--skip-review] [--skip-docs] [--journal] [--wiki] [--dry-run]"
license: MIT
metadata:
  author: adf
  version: "2.0.0"
---

# Ship: Unified Ship Pipeline

Single command to ship a feature, fix or hotfix branch. Fully automated — only stops for test failures, critical review issues, or a git workflow check. The PR target and merge rules come from the project's git workflow (`docs/conventions/git-workflow.md`, `git-flow.cjs`); releases themselves ship with `/git release ship`.

**Inspired by:** gstack `/ship` by Garry Tan. Adapted for framework-agnostic, multi-language support.

## Arguments

| Flag | Effect |
|------|--------|
| (none) | Target from `git-flow.cjs pr-target`: the active release for feat/fix in a release train, main for hotfixes and in trunk |
| `official` | Only with `git.flow: off`: ship to the default branch, full pipeline with docs |
| `beta` | Only with `git.flow: off`: ship to a dev/beta branch, skip docs update |
| `--skip-tests` | Skip test step (use when tests already passed) |
| `--skip-review` | Skip pre-landing review step |
| `--skip-docs` | Skip docs update step |
| `--journal` | Also write a journal entry (default off; use when shipping hit a notable setback) |
| `--wiki` | With `--journal`, also publish the journal to AgentWiki (default off; skipped silently if CLI/MCP absent) |
| `--dry-run` | Show what would happen without executing |

## Target Detection

```
git.flow release-train | trunk → target = git-flow.cjs pr-target (stop if no release is open: suggest /git release cut)
On a release/* branch        → hand over to /git release ship
git.flow off                 → official = default branch, beta = dev/beta/develop, none → AskUserQuestion
```

## When to Stop (blocking)

- On target branch already → abort
- Merge conflicts that can't be auto-resolved → stop, show conflicts
- Test failures → stop, show failures
- Critical review issues → AskUserQuestion per issue
- A `git-flow.cjs check-pr` failure, or a hook that asks or denies → stop, show the reason

## When Not to Stop

- Uncommitted changes that belong to this branch's work → stage them by name; leave unrelated files alone
- Commit message → auto-compose

## Pipeline

```
Step 1:  Pre-flight      → Branch check, mode detection, status, diff analysis
Step 2:  Link Issues      → Find related GitHub issues (never creates one)
Step 3:  Merge target     → Fetch + merge origin/<target-branch>
Step 4:  Run tests        → Auto-detect test runner, run, check results
Step 5:  Review           → Two-pass checklist review (critical + informational)
Step 6:  Version          → Hotfix only: git-flow.cjs bump-version --branch
Step 7:  Changelog        → Skip: written at release time from commit subjects
Step 8:  Journal          → Only with --journal: write entry via /journal, publish to AgentWiki only with --wiki
Step 9:  Docs update      → Update project docs via /docs update (skipped by beta)
Step 10: Commit           → Stage by name, conventional commit
Step 11: Push             → git push -u origin <branch>
Step 12: Create PR        → check-pr, then gh pr create against the target with structured body + linked issues
```

**Detailed steps:** Load `references/ship-workflow.md`
**Auto-detection:** Load `references/auto-detect.md`
**PR template:** Load `references/pr-template.md`

## Token Efficiency Rules

- Steps 4 (tests) and 5 (review): delegate to `tester` and `code-reviewer` subagents — don't inline
- Step 8 (journal, only with `--journal`) runs in **background**. Step 9 (docs) finishes before Step 10 so its edits are committed with the change
- Step 2 (issues): use single `gh` command batch — avoid multiple API calls
- Step 8 (journal): publish to AgentWiki only when `--journal` and `--wiki` are passed AND the `agentwiki` CLI or AgentWiki MCP exists; otherwise skip silently
- Skip steps early via flags to save tokens on unnecessary work
- `beta` (flow off only) auto-skips: docs update (Step 9)
- Capture step outputs inline — don't re-read files already in context

## Quick Start

User says `/ship` → run full pipeline → output PR URL.
User says `/ship` on `hotfix/x` → bump the hotfix version, PR into main.
User says `/ship beta` in a project with `git.flow: off` → ship to the dev branch with the lighter pipeline.

## Output Format

```
✓ Pre-flight: branch feat/foo, 5 commits, +200/-50 lines (target: release/1.4.0)
✓ Issues: linked #42
✓ Merged: origin/release/1.4.0 (up to date)
✓ Tests: 42 passed, 0 failed
✓ Review: 0 critical, 2 informational
✓ Version: set by the release (hotfix: 1.3.0 → 1.3.1)
✓ Journal: written (background, only with --journal)
✓ Docs: updated
✓ Committed: feat(auth): add OAuth2 login flow
✓ Pushed: origin/feat/foo
✓ PR: https://github.com/org/repo/pull/123 (linked: #42, #43)
```

End with one line on watching the PR (Claude Code): `/loop-setup install pr-maintenance` once, then `/loop` in a session of its own.

## Important Rules

- **Never skip tests** (unless `--skip-tests`). If tests fail, stop.
- **Never force push.** Regular `git push` only.
- **Stage by name.** Never `git add -A`, `git add .` or `git commit -a`.
- **Never ask for confirmation** except for critical review issues and git workflow checks.
- **Auto-detect everything else.** Test runner and review scope come from project files; the target branch comes from `git-flow.cjs`.
- **Framework-agnostic.** Works for Node, Python, Rust, Go, Ruby, Java, or any project with a test command.
- **Subagent delegation.** Use `tester` for tests, `code-reviewer` for review, `journal-writer` for the opt-in journal, `docs-manager` for docs. Don't inline.
- **Background tasks.** The opt-in journal runs in background; docs finish before the commit.
- **AgentWiki journal publish.** Only when `--journal` and `--wiki` are passed: after local journal creation, detect `agentwiki` CLI first, then AgentWiki MCP. If available, publish the note as a technical diary/journal with project folder placement, tags, and summary. If unavailable, skip without blocking ship.

## Workflow Position

**Typically follows:** `/adf-code-review` (ship after review passes)
**Optional:** `/journal` when shipping hit a notable setback
**Related:** `/adf-code-review` (review before shipping), `/test` (test before shipping)
