# Agent Teams -- Reference

> **Sources:** https://code.claude.com/docs/en/agent-teams, https://code.claude.com/docs/en/tools-reference, https://code.claude.com/docs/en/hooks, https://code.claude.com/docs/en/sub-agents
> **Checked:** 2026-10-15 against the docs and the tool schemas of Claude Code 2.1.299. Agent teams are experimental; re-check when Claude Code changes them.
> Where the docs are silent, this file says so instead of guessing.

## What a team is

One session is the lead. Teammates are separate Claude Code agents, each with its own context window, that load CLAUDE.md, skills and agents, get their brief from the spawn prompt (the lead's conversation does not carry over), and can message the lead and each other.

| | Subagents | Agent team |
|---|---|---|
| Spawn | `Agent` call | `Agent` call with a `name` (teams enabled) |
| Talk to | the caller only | the lead and other teammates, by name |
| Coordination | the caller manages everything | messages, plus a shared task list when the tools are present |
| Worktree isolation | `isolation: "worktree"` | not available: `isolation` makes the call a subagent, not a teammate |
| Cost | lower | higher, one full agent per teammate |

## Enable

Off by default. Set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in the environment or in settings:

```json
{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
```

With teams enabled, every `Agent` call that has a `name` starts a teammate, also outside `/team`. Every session gets one team when it starts. There is no tool to create or delete a team (the old `TeamCreate` and `TeamDelete` are gone); Claude Code keeps the team record in `~/.claude/teams/<team>/config.json`, with the lead's session id in `leadSessionId`.

## Tools

**Agent** spawns a teammate when it has a `name`: `subagent_type`, `description`, `prompt`, `name`, optional `model`. Agents run in the background, and the lead is notified when one finishes or goes idle. `run_in_background` and `team_name` are no longer parameters (`team_name` is accepted but ignored). From the `subagent_type` definition a teammate gets its `tools` (plus `SendMessage` and the task tools), `model`, `disallowedTools`, `effort` and body, but not its `skills` list; to use a skill, the spawn prompt tells it to read the skill's `SKILL.md` (ADF's definitions do not list the `Skill` tool).

**SendMessage** sends to one agent: `to: "<name>"`, `message: "<text>"`, optional `summary` (a label for the sender's own transcript). There is no broadcast. A message to an idle teammate wakes it. Messages arrive on their own; nobody polls an inbox.

Structured messages put an object in `message`:

| `type` | Sent by | Fields |
|--------|---------|--------|
| `shutdown_request` | lead | `reason` (optional) |
| `shutdown_response` | teammate | `request_id`, `approve`, `reason` |
| `plan_approval_response` | lead | `request_id`, `approve`, `feedback` (see Plan approval) |

**Addressing the lead.** In a team the lead's name is `team-lead`. An agent that runs as a background subagent instead (for example with `isolation`, or in a headless `-p` run) reaches the lead as `main`; `team-lead` is not reachable from there.

**ListAgents** lists the teammates, with whether each is running or idle.

**TaskStop** stops a teammate by name or agent id. Use it when a teammate does not answer a shutdown request.

**TaskCreate / TaskGet / TaskUpdate / TaskList** form the shared task list: the lead creates tasks, and teammates claim them or get them assigned. Claude Code turns these tools on by default only for some models, so a session may not have them. Without them, the spawn prompt is the assignment and messages carry the status. Task fields: `subject`, `description`, `status` (`pending` -> `in_progress` -> `completed`), `owner`, dependencies (`addBlockedBy`, `addBlocks`), `metadata`.

## Shutdown

The lead sends `shutdown_request`. The teammate finishes its current step, then approves (and exits) or rejects with a reason. If it does not answer, `TaskStop` it. Nothing needs cleaning up afterwards.

## Plan approval

A teammate spawned while the lead is in plan mode starts in plan mode, and Claude Code approves its plan request on its own, without the lead reviewing it. Asking for "plan first" in a spawn prompt does not put a teammate in plan mode, so no request arrives. ADF's templates do not use this: when a plan needs a human decision, the lead shows it to the user before spawning (the cook approval gate), or asks the teammate to send its plan as a normal message and wait for a reply.

## Display

The `teammateMode` setting: `"in-process"` (default, every teammate in one terminal), `"auto"`, `"tmux"` or `"iterm2"`. Split panes need tmux, or iTerm2 with the `it2` CLI. The `--teammate-mode` flag is experimental. The docs do not describe a "delegate mode" key binding; ADF's `--delegate` flag is an instruction to the lead, not a Claude Code mode.

## Hook events

Every session's team is named `session-` plus the first eight characters of the session id it started with; a resumed session keeps that team under its new id. Observed on 2.1.299:

- `SubagentStart` fires for each teammate (again when a message wakes it), with the lead's `session_id`, `agent_type` set to the teammate's name, and an opaque `agent_id` (`areviewer-1-06c41150f6f90db3`). `additionalContext` reaches the teammate.
- `TeammateIdle` input: `teammate_name`, `team_name` (deprecated, still sent), `agent_id`. `TaskCompleted` input: `task_id`, `task_subject`, `task_description`, `teammate_name`, `team_name` (deprecated), `agent_id`. For both, the docs list only exit code 2 and `continue: false` as controls.

ADF's team hooks are fail-open. `team-context-inject.cjs` tells a teammate its name, the lead, its peers and the task summary; the two handlers log and print summaries the lead may not see, so templates track progress through messages.

## Practice

- **Brief fully.** Teammates do not see the lead's conversation; put scope, file ownership, acceptance criteria and the report path in the spawn prompt.
- **Size tasks.** Self-contained units with a clear deliverable (a module, a test file, a review). Too small and coordination costs more than the work.
- **Start read-only.** Research and review show the value of a team without the risk of parallel edits.
- **Avoid file conflicts.** Two agents writing the same file overwrite each other. Give each teammate glob ownership with no overlap and let the lead own shared files. ADF's team flows do not use `isolation: "worktree"`: the worktree holds only committed work and the agent's changes stay in it.
- **Idle is not done.** Idle means waiting for input. Check the report or the task status before synthesizing or shutting down.
- **Steer.** Read results as they arrive and redirect early; a team left alone for long wastes tokens.
- **Limit spawning.** Give `Agent` only to agents that genuinely fan out; omit it or list it in `disallowedTools` elsewhere.
- **Permissions.** Teammates start in the lead's permission mode (except `dontAsk`); a teammate's mode can be changed after spawn, not at spawn time. Pre-approve routine commands before a large team, or expect many prompts.

## Limits

- One team per session; teammates cannot lead teams of their own; the lead cannot hand over.
- `/resume` and `/rewind` do not bring back in-process teammates.
- Shutdown waits for the teammate's current request or tool call.
- Split panes do not work in VS Code's integrated terminal; in-process mode works in any terminal.
