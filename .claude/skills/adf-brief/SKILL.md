---
name: adf-brief
description: "Briefs the project from git and plans: a handoff report (branches, worktrees, unfinished plans, roadmap, ranked next steps) or a retro of git metrics over a timeframe."
user-invocable: true
disable-model-invocation: true
context: fork
agent: general-purpose
model: haiku
when_to_use: "Invoke for end-of-session status and handoff, or for a sprint or period retrospective."
argument-hint: "[--fetch] | retro [7d|2w|1m|sprint|YYYY-MM-DD:YYYY-MM-DD] [--compare] [--team] [--issues] [--format md|html]"
category: utilities
keywords: [handoff, wrap-up, status, next-steps, worktree, branches, plans, roadmap, retrospective, sprint, metrics, velocity]
license: MIT
metadata:
  author: adf
  version: "2.0.0"
---

# ADF Brief

Two read-only briefs of the active project, both built on the evidence a scanner script collects:

- **Handoff** (default, `/adf-brief`): where things stand now and what to do next.
- **Retro** (`/adf-brief retro [timeframe]`): what the team delivered in a past window, from git metrics.

Neither mode implements, edits source, commits, checks out, merges or pushes. The only file either writes is the retro report under `plans/reports/`.

Pick the mode from the arguments: the first argument `retro` selects Retro; anything else (or nothing) selects Handoff, and free text is the focus of the handoff.

## Handoff

Run the scanner first from the project root:

```bash
node .claude/skills/adf-brief/scripts/brief-scan.cjs --json
```

Add `--fetch` only when the user asks to refresh remotes before the report.

The scanner:
- scans local branches, remote branch refs and registered worktrees;
- scans unfinished plans from visible worktrees and tracked branch refs, with `- [ ]` / `- [x]` checkbox progress per plan directory (plan.md + phase-*.md);
- scans `docs/requirements/*roadmap*.md` and `docs/requirements/*milestones*.md` (and the legacy `docs/` root) for active milestones;
- emits `nextSteps[]` as `{priority, action, rationale, planId?}`, ranked per plan by status (`in-progress` +400, `in-review` +300, `pending` +150), workspace alignment (current worktree +600, current branch +400), provenance (filesystem +80, local ref +40) and momentum (40-90% complete gets a bump; under 10% a small starter bump). Hygiene steps (dirty tree, detached HEAD) rank first; roadmap milestones fill the remaining slots;
- in a workspace or monorepo with a system map, adds `contractDrift`: which ref each consumer pins per contract and which git dependencies are unpinned (local files only; mention it under Warnings or Next Steps when it shows drift);
- runs no network operation unless `--fetch` is passed, and never changes the checkout.

Report briefly, in this order:

1. **Current State**: branch or detached HEAD, dirty or clean, active worktree.
2. **Recent Work**: only the highest-signal branches and worktrees.
3. **In-Flight Plans**: unfinished plans with `X/Y todos · NN% done`.
4. **Roadmaps**: active milestones, if any.
5. **Next Steps**: 5 to 6 ranked actions, each with a one-line rationale.
6. **Warnings**: scanner failures, the stale remote-ref caveat, detached HEAD.

If the scanner fails, say so with the error, then fall back to read-only commands and say the full scan did not run:

```bash
git status --short --branch
git worktree list --porcelain
git for-each-ref --format='%(refname:short) %(committerdate:iso8601) %(objectname:short) %(subject)' refs/heads refs/remotes
find plans -maxdepth 2 -name plan.md -print
find docs -maxdepth 3 -iname '*roadmap*.md' -print
```

## Retro

Run the scanner in retro mode, passing the timeframe and flags through (default timeframe `7d`):

```bash
node .claude/skills/adf-brief/scripts/brief-scan.cjs --retro 7d [--compare] [--team] [--issues]
```

| Argument | Meaning |
|----------|---------|
| timeframe | `7d`, `2w`, `1m` (whole calendar days ending today), `sprint` (since the latest git tag) or `YYYY-MM-DD:YYYY-MM-DD` (end date inclusive) |
| `--compare` | Delta column against the preceding window of equal length |
| `--team` | Per-author breakdown |
| `--issues` | GitHub issues opened and closed in the window (calls `gh`; N/A when unavailable) |
| `--format md\|html` | Report format; the scanner ignores it, you apply it (default `md`) |

The scanner prints the data sections of the report as Markdown: Velocity, Code Health, Commit Distribution, File Hotspots, Plan Progress, Team Breakdown (with `--team`) and Data Notes. Every number comes from one `git log --numstat` pass over the non-merge commits reachable from the current branch; `N/A` means the data is missing. Its first line, `<!-- save as plans/reports/retro-....md -->`, names the report file. Plan Progress is the current checkbox state of the plans that commits in the window touched, not the work done in the window.

Then write the report:

1. Take the scanner output as is. Do not recompute, round differently or fill in an `N/A`.
2. Append **Highlights** and **Recommendations** following `references/retro-report-template.md`, reading the thresholds in `references/retro-metrics-guide.md`.
3. Save to the path in the first line. With `--format html`, save the same content as a self-contained HTML page with inline CSS at that path ending in `.html`.
4. Reply with the saved path and the 2-3 most important findings.

If the scanner fails, report its error and stop. Do not compute the metrics yourself. For `sprint` in a repo without tags, tell the user to rerun with a date range.

## Security

Do not paste secrets, tokens or customer data from commit subjects, branch names or plans into the report. Author names appear only with `--team`.
