---
name: git
description: "Manage git commits, pushes, PRs, merges, releases and hotfixes under the project's git workflow (release train, trunk or off). Use for commit, push, PR creation, PR merge, cutting or shipping a release, hotfixes, back-merges, CI setup and secret checks."
user-invocable: true
when_to_use: "Invoke for commits, PRs, merges, releases, hotfixes, or any branch or tag decision."
category: dev-tools
keywords: [git, commits, staging, PR, merge, merge-pr, release, hotfix, back-merge, ci]
argument-hint: "cm|cp|pr|merge|merge-pr|release cut|release ship|release status|hotfix|back-merge|setup-ci [args]"
metadata:
  author: adf
  version: "2.0.0"
---

# Git Operations

## Before any branch, PR, merge or release step

1. Read `docs/conventions/git-workflow.md` (the project's process; it may add project-specific duties).
2. Run `node .claude/skills/git/scripts/git-flow.cjs status` for the flow, the active release, and where the current branch's PR goes and how it merges. Never restate or guess these rules; the script reads them from the `git` section of `.claude/config/adf-config.json`.
3. When a hook asks or denies, stop and report its reason. Do not reach the same result another way.

In a workspace (`adf-workspace.json` at the project root), a change spans several repos with their own rules: follow `references/workspace-commits.md` instead of the single-repo steps below.

## Default (No Arguments)

Use `AskUserQuestion` with header "Git Operation", question "What would you like to do?", and these options:

| Operation | Description |
|-----------|-------------|
| `cm` | Stage files by name and commit |
| `cp` | Commit and push |
| `pr` | Open the PR for this branch against the flow's target |
| `merge` | Merge branches locally |
| `merge-pr` | Review, label and merge PRs, then watch CI |
| `release cut <x.y.z>` | Create `release/x.y.z` with the version bump (`--next minor\|patch` picks the version) |
| `release ship` | Changelog, release PR into main, merge when green |
| `release status` | Same as `git-flow.cjs status` |
| `hotfix <issue>` | Branch from main, fix, bump, PR into main |
| `back-merge` | Merge main into the active release after a hotfix |
| `setup-ci` | Add the workflow guards and tagger to CI |

Run mechanical git work (commit, push, open a PR) through the `git-manager` subagent to keep verbose output out of the main context. `merge-pr` and `release ship` run in the main session: they review and edit code and need the user's go-ahead. Activate the `context-engineering` skill. In reports, prefer brevity over full sentences, and pass these rules to subagents.

## Arguments
- `cm`, `cp`: see `references/workflow-commit.md` and `references/workflow-push.md`.
- `pr [to-branch] [from-branch]`: the target defaults to what `git-flow.cjs status` prints (the active release for `feat/*`/`fix/*` in a release train, the main branch for release and hotfix branches). Open it as soon as the branch has a commit, as a draft until ready. See `references/workflow-pr.md`.
- `merge [to-branch] [from-branch]`: see `references/workflow-merge.md`.
- `merge-pr <PR numbers or URLs>`: runs `/review-pr <PR> --fix --reply` first, labels `ready to ship` only when that reports merge-ready, merges with the flow's strategy after `gh pr checks` passes, then watches CI. See `references/workflow-merge-pr.md`.
- `release cut|ship|status`, `hotfix`, `back-merge`: see `references/release-and-hotfix.md`.
- `setup-ci`: see `references/project-customization.md`.

## Core Workflow (commits)

### Step 1: Stage by name
```bash
git status --short
git add -- <path> <path> ...        # only the files this change owns
git diff --cached --stat && git diff --cached --name-only
```
Never `git add -A`, `git add .`, `git add :/` or `git commit -a`: working output (plans, reports, local config) is one bulk add away from a commit. Leave unrelated changes alone; they belong to whoever made them.

### Step 2: Security check
The `commit-guard` hook scans staged changes for secret files and credential formats and asks before committing them. If it asks, unstage the file (`git restore --staged <file>`) and move the value to an untracked `.env`.

### Step 3: Split decision
Split when types mix (feat + fix, code + docs), scopes are unrelated, config or deps mix with code, or more than about 10 unrelated files move. Keep one commit for one type and scope. Search for related GitHub issues and link them in the PR body.

### Step 4: Commit
```bash
git commit -m "type(scope): description"
```
Format and types: `references/commit-standards.md`. `git.commit.pathTypes` may limit the types allowed under a folder; the hook says which.

## Output Format
```
✓ staged: N files (+X/-Y lines)
✓ security: passed
✓ commit: HASH type(scope): description
✓ pushed: yes/no
✓ PR: #N -> <target> (draft|ready)
```

## Error Handling

| Error | Action |
|-------|--------|
| Secrets detected | Stop, list files, unstage |
| No changes | Exit cleanly |
| Hook asks or denies | Stop, report the reason, wait for the user |
| Push rejected | `git pull --rebase` on your own branch; never force-push main or `release/*` |
| Merge conflicts | Resolve by hand, stage the files by name |

## Native hook (offer once)
ADF's hooks are written for Claude Code; other tools may skip them. When the project has no `pre-push` or no `pre-commit` hook from ADF, offer once: `node .claude/skills/git/scripts/git-flow.cjs install-git-hooks` (add `--chain` to keep an existing hook). Only the user runs it; never install the hooks yourself. It writes only into the repository's own git dir and prints a line to add for husky or `.githooks`.

## References

| Task | Reference |
|------|-----------|
| Branch model and PR targets | `references/branch-model.md` |
| Release, hotfix, back-merge, versions, tags | `references/release-and-hotfix.md` |
| Commit across workspace members | `references/workspace-commits.md` |
| Commit | `references/workflow-commit.md` |
| Push | `references/workflow-push.md` |
| Pull request | `references/workflow-pr.md` |
| Merge | `references/workflow-merge.md` |
| Merge PRs | `references/workflow-merge-pr.md` |
| Commit standards | `references/commit-standards.md` |
| Safety | `references/safety-protocols.md` |
| Traps seen in practice | `references/operational-traps.md` |
| Per-project settings, CI setup | `references/project-customization.md` |
| GitHub CLI | `references/gh-cli-guide.md` |
