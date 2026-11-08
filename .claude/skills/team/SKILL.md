---
name: team
description: "Orchestrate Agent Teams for parallel multi-session collaboration. Use for research, implementation, review, and debug workflows requiring independent teammates."
user-invocable: true
when_to_use: "Invoke for coordinated multi-session agent teamwork."
category: dev-tools
keywords: [agents, parallel, multi-session, collaboration]
argument-hint: "<template> <context> [--devs|--researchers|--reviewers N] [--delegate]"
allowed-tools:
  # The pre-flight check only; every other command keeps the normal permission prompt.
  - Bash(printenv CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)
metadata:
  author: adf
  version: "4.0.0"
---

# Agent Teams - ADF-Native Orchestration Engine

Coordinate several Claude Code agents working in parallel. Each teammate has its own context window, loads the project context (CLAUDE.md, skills, agents), and talks to the lead and to other teammates by name.

**Requires:** agent teams are experimental and off by default. Enable them with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in the environment or in the `env` block of `settings.json`, then restart Claude Code.

## Usage

```
/team <template> <context> [flags]
```

**Templates:** `research`, `cook`, `review`, `debug`

**Flags:**
- `--devs N` | `--researchers N` | `--reviewers N` | `--debuggers N` -- team size
- `--plan-approval` / `--no-plan-approval` -- approval gate (default: on for cook)
- `--delegate` -- lead only coordinates, never touches code

## Execution Protocol

**Pre-flight (every template):**
1. Run `printenv CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` as a command of its own (not chained with `;` or `&&`; only that exact command is pre-approved). If it does not print `1`: **stop and tell the user:** "Agent teams are off. Add `"env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }` to `.claude/settings.local.json` (just you) or `.claude/settings.json` (everyone on the project), restart Claude Code, then run /team again."
2. There is nothing to create or delete. Claude Code gives every session one team at startup; an `Agent` call with a `name` adds a teammate to it.

Then IMMEDIATELY execute the matching template below. Do not explain what you are about to do. Ask the user only at the cook approval gate. Report progress after each major step.

### --delegate Mode

When `--delegate` is passed, the lead only spawns teammates, sends messages and synthesizes reports. It never edits files, runs tests or runs git commands itself. For the cook INTEGRATE step, spawn a teammate to make the shared-file edits instead.

---

## Tool Reference (Quick)

| Tool | Use |
|------|-----|
| `Agent` | Spawn a teammate: `subagent_type`, `description`, `prompt`, `name`. Agents run in the background; you are notified when each one finishes or goes idle. |
| `SendMessage` | `to: "<name>"`, `message: "<text>"`. One recipient per call; there is no broadcast, so message each teammate in turn. A message wakes an idle teammate. |
| `ListAgents` | Teammates and whether each one is running or idle. |
| `TaskStop` | Stop a teammate by name, for one that does not answer a shutdown request. |
| `TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet` | Shared task list. **Only some sessions have these tools** (Claude Code turns them on by default for some models only). Use them when present; otherwise the spawn prompt is the assignment and messages are the status. |

**Structured messages** (the `message` field takes an object instead of text):
- Shutdown: `SendMessage(to: "<name>", message: { type: "shutdown_request", reason: "work complete" })`. The teammate approves (and exits) or rejects with a reason.
- Plan approval: Claude Code approves the plans of teammates spawned while the lead is in plan mode on its own, so the templates do not rely on `plan_approval_response`. Cook asks the user to approve the split before any dev starts.

**Names:** never name a teammate after an agent type (`planner`, `tester`, `code-reviewer`...). The team hooks find a teammate by name, and Claude Code reports an ordinary subagent's type in the same field, so a subagent of that type would be taken for the teammate.

**Skills:** a teammate does not get the `skills` list of its agent definition (Claude Code applies that list to subagents only), and ADF's agent definitions do not list the `Skill` tool, which a teammate is limited to. So each spawn prompt below tells the teammate to read the skill's `SKILL.md` and follow it.

---

## ADF Context Block

Every teammate spawn prompt must end with:

```
ADF Context:
- Work dir: {ADF_PROJECT_ROOT or CWD}
- Reports: {ADF_REPORTS_PATH or "plans/reports/"}
- Plans: {ADF_PLANS_PATH or "plans/"}
- Branch: {ADF_GIT_BRANCH or current branch}
- Naming: {ADF_NAME_PATTERN or "YYMMDD-HHMM"}
- Active plan: {ADF_ACTIVE_PLAN or "none"}
- Commits: conventional (feat:, fix:, docs:, refactor:, test:, chore:)
- Team: you are "<your name>"; peers: <names>. Message by name with SendMessage. Reach the lead at "team-lead"; if that name is not reachable, use "main".
- If you cannot write a report file, put the full report in your message to the lead.
- Team rules: read `.claude/skills/team/references/team-coordination-rules.md` before work
```

---

## ON `/team research <topic>` [--researchers N]:

*Wraps /research skill -- scope, gather, analyze, report.*

IMMEDIATELY execute in order:

1. **Derive N angles** from `<topic>` (default N=3):
   - Angle 1: Architecture, patterns, proven approaches
   - Angle 2: Alternatives, competing solutions, trade-offs
   - Angle 3: Risks, edge cases, failure modes, security
   - (If N>3, derive additional angles from topic context)

2. **SPAWN** N teammates in one message, one `Agent` call each:
   - `subagent_type: "researcher"`, `name: "researcher-{i}"`
   - Prompt: `Read .claude/skills/research/SKILL.md and follow its method. Investigate <angle> for topic: <topic>. Format: executive summary, key findings, evidence, recommendations. Do not write files: when done, send the lead the full report with SendMessage.` + ADF Context Block (the researcher definition tells a teammate not to edit files, so the lead saves the reports)
   - If the task tools are present, also `TaskCreate` one task per angle and name its owner.

3. **MONITOR**: completion messages and idle notifications arrive on their own. Check `ListAgents` when unsure. Message a teammate that has been quiet for 5 minutes.

4. **SAVE** each researcher's report from its message to `{ADF_REPORTS_PATH}/researcher-{i}-{ADF_NAME_PATTERN}-{topic-slug}.md`

5. **SYNTHESIZE** into: `{ADF_REPORTS_PATH}/research-summary-{ADF_NAME_PATTERN}-{topic-slug}.md`
   Format: exec summary, key findings, comparative analysis, recommendations, unresolved questions.

6. **SHUTDOWN**: send each teammate that is still running a `shutdown_request`; `TaskStop` any that does not exit. Agents that already finished need nothing.

7. **REPORT**: Tell user `Research complete. Summary: {path}. N reports generated.`
8. **JOURNAL**: Run `/journal` only when the user asks or the work hit a notable setback.

---

## ON `/team cook <plan-path-or-description>` [--devs N]:

*Wraps /cook skill -- plan, code, test, review, finalize.*

IMMEDIATELY execute in order:

1. **READ** plan (if path provided) OR create one first:
   - If description only: spawn `Agent(subagent_type: "planner", name: "planner-1")` with a prompt that says to read .claude/skills/adf-plan/SKILL.md and follow it, and wait for its plan
   - Parse the plan into N independent groups with file ownership boundaries (glob patterns, no overlap; a phase's `touches` may supply them, see `../adf-plan/references/plan-contract.md`)

2. **APPROVAL GATE** (skip with `--no-plan-approval`): show the user the N groups, each with its scope, file ownership and acceptance criteria, and wait for approval.

3. **SPAWN** N developers in one message, one `Agent` call each:
   - `subagent_type: "fullstack-developer"`, `name: "dev-{i}"`
   - No `isolation`: the devs are teammates in the shared checkout, keep strictly to their file ownership, and message each other by name when an interface between groups needs agreeing. Files no group owns stay with the lead, who edits them after the devs finish.
   - Tell each dev not to commit; the user decides when to commit.
   - Prompt: group scope + file ownership + acceptance criteria + plan context + ADF Context Block

4. **MONITOR** until every dev has reported done. An idle notification is not a completion signal: check the dev's report (and task status, if the task tools are present). If a dev is blocked, answer it with `SendMessage`.

5. **INTEGRATE**: make the lead-owned edits to shared files, then check `git status` and `git diff --stat` against the approved file ownership. A file outside every group means a dev crossed its boundary: ask that dev why before keeping it.

6. **TEST**: spawn `Agent(subagent_type: "tester", name: "tester-1")` on the combined result, with a prompt that says to read .claude/skills/test/SKILL.md and follow it. It runs the full suite and reports pass/fail. Fix failures (via the owning dev, or the lead) and test again.

7. **DOCS SYNC EVAL** (required for cook -- from /cook finalize):
   ```
   Docs impact: [none|minor|major]
   Action: [no update needed -- <reason>] | [updated <page>] | [needs separate PR]
   ```

8. **SHUTDOWN** remaining teammates (`shutdown_request`, then `TaskStop` if needed).

9. **REPORT**: Tell user what was cooked, test results, docs impact.
10. **JOURNAL**: Run `/journal` only when the user asks or the work hit a notable setback.

---

## ON `/team review <scope>` [--reviewers N]:

*Wraps /adf-code-review skill -- scout, review, synthesize with evidence gates.*

IMMEDIATELY execute in order:

1. **DERIVE** N review focuses from `<scope>` (default N=3):
   - Focus 1: Security -- vulnerabilities, auth, input validation, OWASP
   - Focus 2: Performance -- bottlenecks, memory, complexity, scaling
   - Focus 3: Test coverage -- gaps, edge cases, error paths
   - (If N>3, derive from scope: architecture, DX, accessibility, etc.)

2. **SPAWN** N reviewers in one message, one `Agent` call each:
   - `subagent_type: "code-reviewer"`, `name: "reviewer-{i}"`
   - Prompt: `Read .claude/skills/adf-code-review/SKILL.md and follow its method, limited to <focus>. Review <scope> for <focus>. Output severity-rated findings only. Format: [CRITICAL|IMPORTANT|MODERATE] <finding> -- <evidence> -- <recommendation>. No "seems" or "probably" -- concrete evidence only. Do not write files: when done, send the lead the full report and finding counts with SendMessage.` + ADF Context Block (the code-reviewer definition tells a teammate not to edit files, so the lead saves the reports)

3. **MONITOR** completion messages; message a reviewer that went idle without reporting.

4. **SAVE** each reviewer's report from its message to `{ADF_REPORTS_PATH}/reviewer-{i}-{ADF_NAME_PATTERN}-{scope-slug}.md`, then **SYNTHESIZE** them into: `{ADF_REPORTS_PATH}/review-{scope-slug}.md`
   - Deduplicate findings across reviewers
   - Prioritize by severity: CRITICAL > IMPORTANT > MODERATE
   - Create action items list with owners

5. **SHUTDOWN** all reviewers (`shutdown_request`, then `TaskStop` if needed).

6. **REPORT**: Tell user `Review complete. {X} findings ({Y} critical). Report: {path}.`
7. **JOURNAL**: Run `/journal` only when the user asks or the work hit a notable setback.

---

## ON `/team debug <issue>` [--debuggers N]:

*Wraps /fix skill -- root-cause-first, adversarial hypotheses, disprove to converge.*

IMMEDIATELY execute in order:

1. **GENERATE** N competing hypotheses from `<issue>` (default N=3):
   - Each hypothesis must be independently testable
   - Each must predict different observable symptoms
   - Frame as: "If <cause>, then we should see <evidence>"

2. **SPAWN** N debuggers in one message, one `Agent` call each:
   - `subagent_type: "debugger"`, `name: "debugger-{i}"`
   - Prompt: `Read .claude/skills/adf-debug/SKILL.md and follow its method. Investigate hypothesis: <theory>. For issue: <issue>. ADVERSARIAL: actively try to disprove the other theories; message the other debuggers (<names>) by name to challenge their findings. Report evidence FOR and AGAINST your theory. Save findings to: {ADF_REPORTS_PATH}/debugger-{i}-{ADF_NAME_PATTERN}-{issue-slug}.md. When done, send the lead your verdict with SendMessage.` + ADF Context Block

3. **MONITOR** messages. Let the debuggers converge; idle means waiting, not done.

4. **READ** each debugger's report (the file, or the message if it could not write one). Identify the surviving theory as the root cause.

5. **WRITE** root cause report: `{ADF_REPORTS_PATH}/debug-{issue-slug}.md`
   Format: Root cause, evidence chain, disproven hypotheses, recommended fix.

6. **SHUTDOWN** all debuggers (`shutdown_request`, then `TaskStop` if needed).

7. **REPORT**: Tell user `Debug complete. Root cause: <summary>. Report: {path}.`
8. **JOURNAL**: Run `/journal` only when the user asks or the work hit a notable setback.

---

## When to Use Agent Teams vs Subagents

| Scenario | Subagents (Agent tool) | Agent Teams |
|----------|----------------------|-------------|
| Focused task (test, lint, single review) | **Yes** | Overkill |
| Sequential chain (plan -> code -> test) | **Yes** | No |
| 3+ independent parallel workstreams | Maybe | **Yes** |
| Competing debug hypotheses | No | **Yes** |
| Cross-layer work (FE + BE + tests) | Maybe | **Yes** |
| Workers need to discuss/challenge findings | No | **Yes** |
| Token budget is tight | **Yes** | No (high cost) |

## Token Budget

| Template | Estimated Tokens | Notes |
|----------|-----------------|-------|
| Research (3) | ~150K-300K | Read-only, moderate cost |
| Cook (4) | ~400K-800K | Highest cost -- code generation |
| Review (3) | ~100K-200K | Read-only, moderate cost |
| Debug (3) | ~200K-400K | Mixed read/execute |

## Agent Memory

Agents with a `memory` scope in their definition keep learnings across sessions: `local` in `.claude/agent-memory-local/<name>/` (gitignored), `project` in `.claude/agent-memory/<name>/`, `user` in `~/.claude/agent-memory/<name>/`. ADF's code-reviewer, debugger, tester, planner, business-analyst and testcase-writer use `local`; researcher uses `user`. Useful for:
- Code reviewer remembering project conventions
- Debugger recalling past failure patterns
- Tester tracking flaky tests and coverage gaps
- Researcher accumulating domain knowledge

## Why Cook Does Not Use Worktrees

`isolation: "worktree"` on the Agent tool gives an agent a worktree built from committed work only, and the agent's changes stay uncommitted in that worktree with no step that brings them back. Cook builds on uncommitted plan work and ADF commits only when the user asks, so its devs share the checkout and are kept apart by file ownership. An agent spawned with `isolation` is also a background subagent, not a teammate. For truly isolated parallel branches, commit first, then run `/worktree` and `/cook` in a separate session per branch.

## Error Recovery

1. **Check status**: `ListAgents`
2. **Redirect**: send the teammate corrective instructions with `SendMessage`
3. **Replace**: stop the failed teammate (`shutdown_request`, then `TaskStop`) and spawn a replacement with the same assignment
4. **Reassign**: if the task tools are present, `TaskUpdate` the stuck task's owner

## Abort Team

Send every running teammate a `shutdown_request`, then `TaskStop` any that is still running. There is no team to delete: Claude Code manages the team record under `~/.claude/teams/`.

## Display Modes

The `teammateMode` setting picks how teammates are shown: `"in-process"` (default, all in one terminal), `"auto"`, `"tmux"` or `"iterm2"`. Split panes need tmux, or iTerm2 with the `it2` CLI.

## Rules Reference

See `.claude/skills/team/references/team-coordination-rules.md` for teammate behavior rules. Tool details, structured messages and limits: `.claude/skills/team/references/agent-teams-reference.md`. Keep these rules skill-local so normal sessions do not spend startup context on Agent Teams.

> v4.0.0: one implicit team per session (no TeamCreate/TeamDelete), teammates are `Agent` calls with a `name`, `SendMessage` takes `to` and `message`, shutdown is a structured message with `TaskStop` as the fallback, the task list is optional, cook devs share the checkout under file ownership.
