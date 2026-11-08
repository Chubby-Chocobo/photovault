# Team Coordination Rules

> These rules only apply when operating as a teammate within an Agent Team.
> They live inside the `team` skill so normal sessions do not load team-only coordination context.

Rules for agents operating as teammates within an Agent Team.

## File Ownership

- Each teammate must own distinct files — no overlapping edits
- Define ownership via glob patterns in task descriptions: `File ownership: src/api/*, src/models/*`
- Lead resolves ownership conflicts by restructuring tasks or handling shared files directly
- Tester owns test files only; reads implementation files but never edits them
- If ownership violation detected: Stop and report to lead immediately

## Git Safety

- Implementation teams share one checkout: edit only the files you own, and leave shared files to the lead
- Never force-push from a teammate session
- Do not commit unless the lead tells you to; in ADF the user decides when to commit
- Pull before push to catch merge conflicts early
- If working in a git worktree, commit/push to the worktree branch — not main or dev

## Communication Protocol

- Message the lead or a peer with `SendMessage` (`to: "<name>"`, `message: "<text>"`); there is no broadcast
- Your spawn prompt is your assignment. If you have the task tools, also mark the task completed via `TaskUpdate` BEFORE sending the completion message
- Include actionable findings in messages, not just "I'm done"
- Never send structured JSON status messages — use plain text

## ADF Stack Conventions

### Report Output
- Save reports to `{ADF_REPORTS_PATH}` (injected via hook, fallback: `plans/reports/`). If your spawn prompt or agent definition says not to write files (reviewers, researchers), send the full report to the lead by message instead
- Naming: `{type}-{date}-{slug}.md` where type = your role (researcher, reviewer, debugger)
- In reports, prefer brevity over full sentences. List unresolved questions at end.

### Commit Messages
- Use conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`
- No AI references in commit messages
- Keep commits focused on actual code changes

### Docs Sync (Implementation Teams Only)
- After completing implementation tasks, lead must evaluate docs impact
- State explicitly: `Docs impact: [none|minor|major]`
- If impact: update `docs/` directory or note in completion message

## Task Claiming (only when you have the task tools)

- Claim lowest-ID unblocked task first (earlier tasks set up context for later ones)
- Check `TaskList` after completing each task for newly unblocked work
- Set task to `in_progress` before starting work
- If all tasks blocked, notify lead and offer to help unblock

## Plan Approval Flow

When the lead asks you to plan first:
1. Research and plan your approach (read-only — no file edits)
2. Send the plan for approval (`ExitPlanMode` when you are in plan mode; otherwise send it to the lead with `SendMessage`)
3. Wait for the lead's reply
4. If rejected: revise based on feedback, resubmit
5. If approved: proceed with implementation

## Conflict Resolution

- If two teammates need the same file: escalate to lead immediately
- If a teammate's plan is rejected twice: lead takes over that task
- If findings conflict between reviewers: lead synthesizes and documents disagreement
- If blocked by another teammate's incomplete work: message them directly first, escalate to lead if unresponsive

## Shutdown Protocol

- Approve shutdown requests unless mid-critical-operation
- Mark current task completed before approving shutdown only when the assigned work is actually complete
- If work is incomplete, leave status unchanged or mark blocked with a concise handoff before approving or rejecting shutdown
- If rejecting shutdown, explain why concisely
- Answer with `SendMessage(to: "<lead>", message: { type: "shutdown_response", request_id: "<from the request>", approve: true | false, reason: "..." })`; approving ends your session

## Idle State (Normal Behavior)

- Going idle after sending a message is NORMAL — not an error
- Idle means waiting for input, not disconnected
- Sending a message to an idle teammate wakes them up
- Do not treat idle notifications as completion signals — check the report or task status instead

## Discovery

- Your spawn prompt names your peers; `ListAgents` lists everyone if you have it
- The lead is `team-lead`; if that name is not reachable (you were started as a background agent), send to `main`
- Always refer to teammates by NAME (not agent ID)
- Names are used for: `to` in SendMessage, task `owner` in TaskUpdate
