# Claude Code Hooks

This directory contains hooks for Claude Code sessions.

## Hooks Overview

Registered hooks live in `.claude/settings.json` (project-local, single source of truth). The per-project installer merges ADF hooks into existing settings (preserves user hooks).

| Hook | Location | Event / matcher | Description |
|------|----------|-----------------|-------------|
| **Session Init** | `session-init.cjs` | SessionStart `startup\|resume\|clear\|compact` | Session startup initialization |
| **Simplify Gate** | `simplify-gate.cjs` | UserPromptSubmit | Advisory only: adds a reminder when ship/commit verbs appear while the working tree has a large unsimplified diff. Never blocks the prompt. Stateless (reads `git diff HEAD`). Ship verbs: ship, merge, pr, deploy, publish. Commit verbs: commit, finalize, release. Bypass: `ADF_SIMPLIFY_DISABLED=1` or `hooks.simplify-gate: false` in `adf-config.json` |
| **Dev Rules** | `dev-rules-reminder.cjs` | UserPromptSubmit | Development rules injection |
| **Subagent Init / Team Context** | `subagent-init.cjs`, `team-context-inject.cjs` | SubagentStart | Context injection for subagents and agent-team members |
| **Descriptive Name** | `descriptive-name.cjs` | PreToolUse `Write` | Reminds to use descriptive kebab-case file names |
| **Scout Block** | `scout-block.cjs` | PreToolUse `Bash\|Glob\|Grep\|Read\|Edit\|Write` | Blocks read/search commands on heavy directories (default: node_modules, .venv, venv, __pycache__, .pytest_cache, .mypy_cache, .next, cache). Edit and Write are never blocked. Ignore list: `.claude/config/adf-ignore.txt` |
| **Privacy Block** | `privacy-block.cjs` | PreToolUse `Bash\|Glob\|Grep\|Read\|Edit\|Write` | Sensitive-file access returns `permissionDecision: "ask"`, so Claude Code shows its native permission prompt. Not in auto mode (`adf-mode.cjs`), where the call proceeds and the `permissions.deny` rules still apply. Fail-open on errors |
| **Ask Gate** | `ask-gate.cjs` | PreToolUse `AskUserQuestion` | In auto mode denies the question with an instruction to take the recommended option and record it in the plan; silent in strict mode. Fail-open |
| **Manifest Credential Redact** | `manifest-credential-redact.cjs` | PostToolUse `Read\|Bash\|Grep\|Edit\|MultiEdit` | Masks credentials embedded in URLs (`https://TOKEN@host`) in tool output and adds a note to use a deploy key or a credential helper instead. One node process per call that exits at once when the output has no URL with an `@`. Off with `hooks.manifest-credential-redact: false`. Fail-open |
| **Plan Format Kanban** | `plan-format-kanban.cjs` | PostToolUse `Edit\|Write` | Warns when `plan.md` uses file names as link text instead of readable names (kanban view). Fail-open |
| **Session State** | `session-state.cjs` | PostToolUse `Agent\|Task\|TaskCreate\|TaskUpdate`, SubagentStop, Stop, PreCompact | Persists session progress (PreCompact writes the latest state before compaction) as markdown (no per-subagent sections) and refreshes the statusline activity cache. Non-blocking, disable with `hooks.session-state: false` |
| **Commit Guard** | `commit-guard.cjs` | PreToolUse `Bash`, `if: Bash(git *)` (so `git -C <dir> commit` is checked too; exits at once for other git commands) | Asks (refuses in auto mode, where nobody can approve) before a commit records secret files (`.env`, private keys) or lines matching known credential formats (AWS, GitHub, Slack, Stripe, Google, Anthropic, OpenAI, npm). Because it runs before the command stages anything, it also scans what the command will add: `git add .`/`-A` → all changes and untracked files, `git add <paths>` and `git commit <paths>` → those paths, `git add -u`/`commit -a` → tracked changes, `git add -f` → ignored files too. An inline `cd <dir>`, `pushd <dir>`, `git -C <dir>` and `git --git-dir` (a `.git` directory) move the scan to that directory, so `cd pkg && git add . && git commit` scans `pkg`. Diffs are read with fixed prefixes and unquoted paths, whatever the user's git config. Shows rule and file:line, never the value; `adf-allow-secret` on a line skips it. The message (conventional format, under 72 characters, no trailing period, no AI attribution), `commit -a`, a `git add -A`/`.` that runs before the commit in the same directory (git-flow-guard leaves it here, so it shares one reason with the secrets: Claude Code passes on one reason when two hooks ask), the types `git.commit.pathTypes` allows per folder, and commits made straight on the main branch are checked at `git.enforcement` (`off`/`ask`/`deny`; the older `commitGuard.messageFormat` still decides when set; the direct-commit check at most asks). Disable with `hooks.commit-guard: false` |
| **Git Flow Guard** | `git-flow-guard.cjs git` / `gh` | PreToolUse `Bash`, `if: Bash(git *)` / `if: Bash(gh pr *)` | Holds commands to the project's git workflow (`git` in adf-config.json). `git add -A`/`.`/`:/` → stage by name (left to commit-guard when a commit in the same directory follows); `git push`: force-pushing or deleting the main branch is always denied (also `release/*` force pushes), a direct push to main runs `check-push`, a new feat/fix/hotfix branch gets a reminder to open its PR; `git tag` or a pushed release tag → CI owns tags; `gh pr create` → `check-pr` against the flow; `gh pr merge` → the flow's strategy, green `gh pr checks`, `--auto` denied without branch protection, `--delete-branch` with child PRs asks. Parses `&&`/`;` chains, `cd`/`pushd`, `git -C`, env prefixes and refspecs (`HEAD:main`, `+main`, `:branch`). Lookups that fail or time out ask, never deny. Levels from `git.enforcement`; `flow: off` keeps only the safety rules. Disable with `hooks.git-flow-guard: false` |
| **Verify Before Stop** | `verify-before-stop.cjs` | PostToolUse `Edit\|Write\|NotebookEdit\|Bash`, Stop | Records code edits and test/lint/typecheck/build commands per session (temp file, transcript not parsed). On Stop with unverified edits, blocks once and asks Claude to run the narrowest check or say why none applies; the retry always stops. The edited-file list stays until a check runs (the statusline shows it as `⚠ N unverified`); new edits after a reminder get a new one. Docs, config, files without an extension, `plans/`, `docs/` and files outside the project do not count; `npm ci`, `make clean` and similar do not count as checks. Extra commands: `verifyBeforeStop.commands`. Disable with `hooks.verify-before-stop: false` |
| **Lint On Edit** | `lint-on-edit.cjs` | PostToolUse `Edit\|Write`, `async` + `asyncRewake` | Opt-in (`lintOnEdit.enabled: true`). Lints the edited file with the project's Biome/ESLint (from `node_modules`) or Ruff and wakes Claude with the output only when the linter exits 1 (problems found); config errors and crashes stay silent. Never rewrites files. Lints the whole file, so problems that predate the edit are reported too, and with rapid edits an older run can report problems a later edit already fixed |
| **Desktop Notify** | `desktop-notify.cjs` | Notification | Desktop notification (macOS `osascript`, Linux `notify-send`) when Claude waits for permission or input. Types: `notify.types`. Disable with `hooks.desktop-notify: false` |
| **Cook After Plan** | `cook-after-plan-reminder.cjs` | PostToolUse `Agent` (acts on `subagent_type` `Plan` or `planner`, only once the agent has completed) | Adds context telling Claude to ask the user for the next step (implement, validate, audit, revise, end) after planning, with the absolute plan path. A SubagentStop hook cannot do this: its plain stdout never reaches the parent session |
| **Workflow Artifact Gate** | `workflow-artifact-gate.cjs` | Not registered by default (opt-in) | Validates fix/cook review artifacts before finalize and ship-like actions. Skills call it through the shared hook-path resolver in `skills/_shared/`; manual CLI mode (`--stage`, `--artifact-dir`, `--json`) always validates and exits non-zero when blocked |
| **Task Completed / Teammate Idle** | `task-completed-handler.cjs`, `teammate-idle-handler.cjs` | TaskCompleted, TeammateIdle | Logs completions to `{reports}/team-{name}-completions.md`. Their progress summaries are informational: Claude Code does not inject hook context for these events. Fail-open |
| **Notifications** | `notifications/` | Opt-in | Multi-provider notification system (Telegram, Discord, Slack) |

## Hook Registration (Project-Local)

- **Project mode** (`.claude/settings.json`): Commands use `node ".claude/hooks/<name>.cjs"`.
- **Installation** (`bash install.sh <project>`): Merges ADF hook entries into existing `.claude/settings.json`, keeping handler fields such as `if`, `async` and `asyncRewake`. The install manifest records which hook commands ADF added, so re-running updates only those and uninstall removes only those; user hooks and keys are preserved.

## Notifications

Unified Node.js notification system with multi-provider support, smart throttling, and zero dependencies.

> **Note:** Notification hooks are NOT enabled by default. Follow the setup guide below to enable them.

### Supported Providers

| Provider | Env Variables Required | Setup Guide |
|----------|----------------------|-------------|
| **Telegram** | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | [telegram-hook-setup.md](../notifications/docs/telegram-hook-setup.md) |
| **Discord** | `DISCORD_WEBHOOK_URL` | [discord-hook-setup.md](../notifications/docs/discord-hook-setup.md) |
| **Slack** | `SLACK_WEBHOOK_URL` | [slack-hook-setup.md](../notifications/docs/slack-hook-setup.md) |

### Setup Guide

#### Step 1: Configure Environment Variables

Copy the example and add your credentials:

```bash
cp .claude/hooks/notifications/.env.example .claude/.env
```

Edit `.claude/.env`:
```bash
# Telegram (get token from @BotFather, chat_id from getUpdates API)
TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrsTUVwxyz
TELEGRAM_CHAT_ID=987654321

# Discord (create webhook: Server Settings > Integrations > Webhooks)
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...

# Slack (create app at api.slack.com/apps, enable Incoming Webhooks)
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
```

Only configure the providers you want to use.

#### Step 2: Enable Notification Hooks

Add to your `.claude/settings.json` or `.claude/settings.local.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "node \"$CLAUDE_PROJECT_DIR/.claude/hooks/notifications/notify.cjs\""
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "node \"$CLAUDE_PROJECT_DIR/.claude/hooks/notifications/notify.cjs\""
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "node \"$CLAUDE_PROJECT_DIR/.claude/hooks/notifications/notify.cjs\""
          }
        ]
      }
    ]
  }
}
```

**Available Hook Events:**
- `Stop` - Main session completion
- `SubagentStop` - Subagent task completion
- `Notification` - Claude notification events (input prompts, etc.)

Choose only the events you want notifications for.

#### Step 3: Test Your Setup

```bash
echo '{"hook_event_name":"Stop","cwd":"'$(pwd)'","session_id":"test123"}' | node .claude/hooks/notifications/notify.cjs
```

Expected output (if Telegram and Discord configured):
```
[env-loader] Loaded: /home/user/.claude/.env
[notify] telegram: sent
[notify] discord: sent
[notify] Summary: 2/2 succeeded
```

### Features

- **Smart Throttling**: 5-minute quiet period after errors to prevent spam
- **Env Cascade**: `process.env` > `.claude/.env` (project-local)
- **Zero Dependencies**: Uses native Node.js fetch (Node 18+)
- **Cross-Platform**: Uses `path.basename()` for Windows compatibility
- **Non-Blocking**: Always exits 0 to never block Claude
- **Selective Providers**: Only configured providers receive notifications

### Architecture

```
notifications/
├── notify.cjs           # Main router - reads stdin, routes to providers
├── .env.example         # Environment template
├── docs/                # Provider setup guides
├── lib/
│   ├── env-loader.cjs   # Env cascade loader
│   └── sender.cjs       # HTTP sender with throttling
└── providers/
    ├── telegram.cjs     # Telegram Bot API
    ├── discord.cjs      # Discord webhooks with embeds
    └── slack.cjs        # Slack Block Kit format
```

## Scout Block Hook

Cross-platform hook blocking heavy directories to improve Claude performance.

**Blocked Patterns** (baseline in `.claude/config/adf-ignore.txt`, optional override in `<project-root>/.claude/config/adf-ignore.txt`):
- `node_modules`, `__pycache__`, `.git`, `dist`, `build`

**Testing:**
```bash
echo '{"tool_input":{"command":"ls node_modules"}}' | node .claude/hooks/scout-block.cjs
```

## Workflow Artifact Gate

Validates structured review artifacts generated by `fix` and `cook`.
Manual use:

```bash
node .claude/hooks/workflow-artifact-gate.cjs --stage finalize --artifact-dir plans/example/reports/harness
```

Opt in through `.claude/config/adf-config.json`:

```json
{
  "hooks": {
    "workflow-artifact-gate": true
  },
  "workflowArtifactGate": {
    "enabled": true,
    "softStages": ["finalize", "commit"],
    "hardStages": ["ship", "push", "pr", "deploy"],
    "highRiskAutoStop": true
  }
}
```

Then add hook commands to `.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \".claude/hooks/workflow-artifact-gate.cjs\""
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node \".claude/hooks/workflow-artifact-gate.cjs\""
          }
        ]
      }
    ]
  }
}
```

Emergency disable: set `ADF_WORKFLOW_ARTIFACT_GATE_DISABLED=1` or set
`hooks.workflow-artifact-gate` to `false`.

## Security

1. **Never commit tokens** - Add `.env` to `.gitignore`
2. **Use environment variables** - Never hardcode credentials
3. **Rotate tokens regularly** - Regenerate periodically

## Troubleshooting

**No notifications received:**
- Verify env vars are set: `echo $TELEGRAM_BOT_TOKEN`
- Check throttle state: `cat /tmp/adf-noti-throttle.json`
- Test manually with echo pipe above

**Provider throttled:**
- Wait 5 minutes or delete `/tmp/adf-noti-throttle.json`

**Hooks not triggering:**
- Verify hooks are added to `.claude/settings.json`
- Check Claude Code is using correct settings file

---

**Last Updated:** 2025-12-21
