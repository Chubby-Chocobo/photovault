---
name: loop-setup
description: "Installs an ADF template as .claude/loop.md, the prompt a bare /loop runs: PR maintenance, release watch, or plan sync. Claude Code only."
user-invocable: true
disable-model-invocation: true
when_to_use: "Invoke to choose, inspect or remove the project's /loop template."
category: utilities
keywords: [loop, schedule, maintenance, pr, ci, release, plan]
argument-hint: "[list | show <template> | install <template> [--force] | remove [--force] | status]"
metadata:
  author: adf
  version: "1.0.0"
---

# Loop Setup

`/loop` with no prompt runs `.claude/loop.md` (or `~/.claude/loop.md`, or Claude Code's built-in maintenance prompt when neither exists). This skill installs one of ADF's templates there. Nothing is installed until the user runs it.

## Templates

| Template | Each iteration | Writes |
|---|---|---|
| `pr-maintenance` | Checks the current branch's PR (including inline review comments): fixes failing CI, acts on comments from the PR author and repo members only. Stops when the branch changes, the PR is merged, closed or conflicted, or the checkout has changes the loop did not make | Commits only the files it changed and pushes to the PR branch; never the default branch, never force, never merge. CI, dependency and script changes are proposed, not made |
| `release-watch` | Watches the default branch's workflow runs for its latest commit on GitHub; reports the failing step and a proposed fix, or the release for that commit | Nothing |
| `plan-sync` | Ticks plan todos that code and a passing check prove done; marks the plan completed at the end | `plans/` only |

## Usage

Run the script and relay its output. It writes to `$CLAUDE_PROJECT_DIR`, else (in a git repo) the nearest directory upward to the top level that has `.claude/`, else the top level; outside git, the current directory:

```bash
node .claude/skills/loop-setup/scripts/loop-template.cjs <command>
```

- No argument or `list`: list templates and show what `.claude/loop.md` is now.
- `show <template>`: print a template so the user can read it before installing.
- `install <template>`: write `.claude/loop.md`. An untouched ADF template, including an older version of one, is replaced. A custom or edited file is not (exit 2): tell the user, and add `--force` only after they agree.
- `remove`: delete `.claude/loop.md` when it is an untouched ADF template. A custom or edited file needs `--force` and the user's agreement.
- Before `--force` replaces or deletes a file, it is copied to `.claude/backups/loop-md/` (gitignored by the project installer's `.claude/.gitignore` block, kept on uninstall; without that block the backup shows up as an untracked file). A symlinked `loop.md` is never written through.
- `status`: report what `.claude/loop.md` is.

After installing, tell the user:
- Start it with `/loop`. `/loop <prompt>` ignores `loop.md` and runs that prompt instead.
- The loop lives in this session only: closing the session stops it, Esc cancels the next wakeup, and a fixed-interval loop expires after seven days.
- Run it in a session of its own (`claude -n pr-watch`) so it does not fill the working session's context. It shares the checkout, so do not edit files there while it runs; `pr-maintenance` stops when it finds changes it did not make or the branch changes. Run at most one loop per branch.
- Unattended use: see `## Unattended runs` below.

## Unattended runs

- A `permissions.ask` rule (destructive commands) or the commit-guard hook (secrets) pauses the loop until someone answers; the desktop-notify hook tells the user. To avoid pauses for ordinary commands, enable the OS sandbox with `autoAllowBashIfSandboxed`; deny rules, content-specific ask rules such as `Bash(rm -rf *)`, and commit-guard still apply.
- The verify-before-stop hook still runs, so an iteration that edits code is asked to run a check before it ends.
- Each template has a stop condition. Without one, a self-paced loop keeps waking up for up to seven days.
- Self-paced loops (`/loop` with no interval) are usually cheaper than a fixed interval: Claude checks often while CI runs and backs off to an hour when nothing changes.

## Notes

- An installed file starts with `<!-- adf-loop-template: <name> sha256:<hash> -->`, the hash of the text below it; the script uses it to tell untouched templates from edited or custom files.
- Edits to `.claude/loop.md` apply from the next iteration; content past 25,000 bytes is truncated.
- `/loop` and `loop.md` are Claude Code features; Antigravity has no equivalent.
