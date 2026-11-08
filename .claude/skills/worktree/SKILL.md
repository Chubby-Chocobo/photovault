---
name: worktree
description: "Create, inspect, and clean isolated git worktrees. Use for feature isolation, worktree health audits, stale cleanup, and monorepo or submodule workflows."
user-invocable: true
when_to_use: "Invoke for isolated worktrees, stale cleanup, or worktree audits."
category: dev-tools
keywords: [worktree, parallel, monorepo, isolation]
argument-hint: "[feature-description] OR [project] [feature]"
metadata:
  author: adf
  version: "1.1.0"
---

# Git Worktree

Create an isolated git worktree for parallel feature development.

## Workflow

### Step 1: Get Repo Info

```bash
node .claude/skills/worktree/scripts/worktree.cjs info --json
```

Parse JSON response for: `repoType`, `baseBranch`, `projects`, `worktreeRoot`,
`worktreeRootSource`, `dirtyState`, `dirtyDetails`.

### Step 2: Detect Branch Naming Mode

**Check for exact branch name first:**
If caller provides a pre-formed branch name (contains uppercase letters, issue tracker keys like `ABC-1234`, forward slashes for multi-segment conventions like `user/type/feature`, or explicitly says "use this exact branch name"):
→ Use `--no-prefix` flag — skip Step 3, pass name directly as slug.
Examples:
- `"ND-1377-cleanup-docs"` → `--no-prefix` → branch `ND-1377-cleanup-docs`
- `"kai/feat/604-startup-option"` → `--no-prefix` → branch `kai/feat/604-startup-option`

**Otherwise, detect prefix from description:**
- "hotfix", "production", "urgent", "prod down" → `hotfix` (starts from the main branch)
- "fix", "bug", "error", "issue" → `fix`
- "refactor", "restructure", "rewrite" → `refactor`
- "docs", "documentation", "readme" → `docs`
- "test", "spec", "coverage" → `test`
- "chore", "cleanup", "deps" → `chore`
- "perf", "performance", "optimize" → `perf`
- Default → `feat`

### Step 3: Convert to Slug

**Skip if `--no-prefix` was chosen in Step 2.**

"add authentication system" → `add-auth`
"fix login bug" → `login-bug`
Max 50 chars, kebab-case.

### Step 4: Handle Monorepo or Workspace

If `repoType` is `"monorepo"` or `"workspace"` and project not specified, use AskUserQuestion:
```javascript
AskUserQuestion({
  questions: [{
    header: "Project",
    question: "Which project for the worktree?",
    options: projects.map(p => ({ label: p.name, description: p.path })),
    multiSelect: false
  }]
})
```

### Step 5: Execute

**Monorepo:**
```bash
node .claude/skills/worktree/scripts/worktree.cjs create "<PROJECT>" "<SLUG>" --prefix <TYPE>
```

**Workspace** (project root has `adf-workspace.json`): the projects are the cloned members and the sibling submodules. `create <member> <slug>` branches inside that member (from its own flow's base), warns when the member has uncommitted changes, and places the worktree under `<workspace>/worktrees/`. For a plan that spans members, create one worktree per member in the plan's `scope`, with the same branch name:
```bash
node .claude/skills/worktree/scripts/worktree.cjs create-scope "<SLUG>" --plan plans/<plan-dir> --prefix <TYPE> --json
node .claude/skills/worktree/scripts/worktree.cjs remove-scope "<SLUG>" --plan plans/<plan-dir> --dry-run --json
```
`create-scope` also checks out submodules, is safe to re-run (members that already have the worktree come back as `existing`), and reports every member as `created`, `existing` or `failed`; a member that is not cloned fails without stopping the others. `remove-scope` removes those worktrees under the `remove` rules and keeps the branches. Run both at the workspace root. Do not use `claude --worktree` at the workspace root: it checks out the workspace repo without its members.

**Standalone:**
```bash
node .claude/skills/worktree/scripts/worktree.cjs create "<SLUG>" --prefix <TYPE>
```

**Options:**
- `--prefix` - Branch type: feat|fix|refactor|docs|test|chore|perf
- `--base <branch>` - Override the base branch. Default: the git workflow's (`git` in `.claude/config/adf-config.json`): the active release for `feat`/`fix` and other work in a release train, the main branch for `hotfix` and in trunk; with `git.flow: off`, dev→develop→main→master. With no open release, a release train starts from the main branch and warns.
- `--checkout-submodules` - Run `git submodule update --init --checkout --recursive` in the new worktree after create
- `--no-prefix` - Skip branch prefix and preserve original case and slashes (for Jira keys, multi-segment branches like `user/type/feature`)
- `--worktree-root <path>` - Override default location (only if needed)
- `--json` - JSON output
- `--dry-run` - Preview
- `--force` - `remove` only: discard uncommitted work (see Removing a worktree)
- `--delete-branch` - `remove` only: also delete the branch with `git branch -d`

### Step 6: Install Dependencies

Based on project context, run in background:
- `bun.lock` → `bun install`
- `pnpm-lock.yaml` → `pnpm install`
- `yarn.lock` → `yarn install`
- `package-lock.json` → `npm install`
- `poetry.lock` → `poetry install`
- `requirements.txt` → `pip install -r requirements.txt`
- `Cargo.toml` → `cargo build`
- `go.mod` → `go mod download`

## Commands

| Command | Usage | Description |
|---------|-------|-------------|
| `create` | `create [project] <feature>` | Create worktree |
| `remove` | `remove <exact-name-or-path> [--force] [--delete-branch]` | Remove worktree; see Removing a worktree |
| `create-scope` | `create-scope <feature> --plan <dir> [--prefix t] [--dry-run]` | Workspace: one worktree per member in the plan scope |
| `remove-scope` | `remove-scope <feature> --plan <dir> [--dry-run] [--force]` | Workspace: remove those worktrees; branches kept |
| `info` | `info` | Repo info with worktree location |
| `list` | `list` | List worktrees |
| `status` | `status` | Inspect worktree health, normalized paths, and base-branch divergence |
| `prune` | `prune` | Clean stale worktree metadata (`--dry-run` supported) |

## Removing a worktree

WARNING: `--force` discards uncommitted and untracked work in the worktree and cannot be undone. Never pass it unless the user asked for it.

- Run `remove <target> --dry-run` first and confirm the target with the user.
- The target must match a worktree's name, path or branch exactly. A partial match is refused: the command lists the candidates and exits non-zero; re-run with the exact value.
- A worktree with uncommitted or untracked changes is refused (`WORKTREE_DIRTY`). Ask the user to commit or stash, or to approve `--force`.
- The branch is kept. `--delete-branch` also runs `git branch -d`; if git says the branch is unmerged, the worktree is still removed, the branch stays and the error names `git branch -D` for the user to run. Never run `-D` yourself.

## JSON Output Fields

When using `--json`, the command surfaces these high-signal fields:

| Field | Description |
|-------|-------------|
| `baseBranch` | Branch the worktree is based on |
| `baseBranchSource` | `"explicit"` (from `--base`), `"git-workflow"` or `"auto-detected"` |
| `checkoutSubmodules` | Whether create will initialize submodules after checkout |
| `currentWorktree` | Current worktree health record from `status --json` |
| `worktrees` | Normalized worktree records from `list --json` or `status --json` |
| `entries` | Prune output lines from `prune --json` |
| `worktreePath` | Absolute path to the created worktree |
| `worktreeRootSource` | How location was determined |

## Notes

- Script auto-detects workspace, superproject, monorepo, and standalone repos
- In a workspace, members are separate repos: `git worktree` runs inside the member, and git hooks apply that member's rules in its worktree
- Default worktree location is smart: superproject > monorepo > sibling
- Use `--worktree-root` only to override defaults
- Use `--base` for long-lived variant branches (e.g., `main-dsl`) that diverge from auto-detected base
- `status` normalizes the main checkout path in submodule repos before reporting worktree health
- `prune --dry-run` is the safe first pass when auditing stale metadata
- Env templates (`.env*.example`) auto-copied with `.example` suffix removed

## Workflow Position

**Typically precedes:** `/cook` (implement in worktree), `/fix` (fix in worktree)
**Setup skill** — creates isolated environment before implementation.
