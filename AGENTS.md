<!-- >>> ADF (managed by install.sh: replaced on update, removed on uninstall) >>> -->
# ADF (Agentic Development Framework)

Rules for any AI coding agent (Codex, Cursor, Copilot, Gemini, Grok, Antigravity, Claude Code, ...) working in this project. Nothing under `.claude/` is required reading.

Docs root: `docs/` (paths below that start with `docs/` are in this folder)

## Start here

1. Read `README.md`, then `docs/README.md` (the map of the docs).
2. Read the files in `docs/conventions/` whose `description` fits your task. `docs/conventions/agent-rules.md` holds this project's own rules. Read `git-workflow.md` before any branch, commit or pull request step.
3. In a monorepo component or workspace member folder, also read the `AGENTS.md` in that folder.
4. Older projects: also read `.claude/rules/project-*.md` if present (project rules from before `docs/conventions/`).

## Safety (always)

- Never read or print `.env*` files (templates such as `.env.example` are fine), keys, `secrets.y(a)ml`, credentials files, `.mcp.json`, `~/.ssh` or `~/.aws`. Never echo a secret into chat, logs or commits.
- Ask the user before `rm -rf`, `git reset --hard`, `git clean`, force push, `git branch -D`, `DROP` or `TRUNCATE`. If they decline, do not reach the same result another way.
- Never use `--no-verify` on `git commit` or `git push` (nor `-n` on `git commit`) unless the user says so.
- ADF's hooks are written for Claude Code; other tools may skip them or let them fail open, so follow these rules yourself.
- When a hook refuses a commit or push, stop and tell the user. Never add `adf-allow-secret`, change `commitGuard` settings, or edit, disable or uninstall git hooks unless the user says so. Never install git hooks; a person does.

## Git

- Commit or push only when the user asks. Stage files by name; never `git add -A`, `git add .` or `git commit -a`.
- Conventional commits (`type(scope): description`), header under 72 characters, no AI references, no plan or phase ids. Never force-push the main branch or a release branch. Never edit `CHANGELOG.md` on a feature branch; it is written on the release branch.
- Flow, main branch and where pull requests go: the settings block of `docs/conventions/git-workflow.md`. If that file has no settings block, its "Branch model" section applies. If the file is missing, no branch model applies: work on the current branch and ask the user where a pull request goes.

## Workflow

- Order: understand, plan, implement, test, review, update docs. Plan in `plans/` for broad or risky work; implement real behavior, scoped to the request; test the narrowest thing first and never hide a failure; review your own diff; update `docs/` when behavior or architecture changed.
- When nobody can answer (a non-interactive run such as `claude -p` or `codex exec`, a prompt that says it runs unattended, auto mode, or no way to ask): never wait. Choose by the stated principles (the brief's `## Principles`, then the plan's, then the project's conventions), else the recommended option, and record it under `## Decisions` in the active plan (topic, chosen, alternatives, why, review later), or where the task says, or in your final reply when there is no plan. Stop and report only when every option breaks a stated principle or a required input cannot be read.
- Pick the lightest workflow that meets the request and the project's architecture; hand broad or parallel work to sub-agents if your tool has them, and do small work directly.
- Plans: `plans/<yymmdd-hhmm>-<slug>/plan.md` and `phase-NN-<name>.md`. Reports: `plans/reports/`, short, unresolved questions last.
- "How long will it take?": give size (S, M or L), the hours a person spends and the unknowns; never dates.
- New project rules go in `docs/conventions/<topic>.md` with a one-line `description` in its front matter. When two rule files conflict, ask the user.
- Do not edit ADF's own files: the `.claude/` files the installer replaces, and this ADF block of `AGENTS.md`. Put project text outside the block's markers.
- Split a code file past about 200 lines along real boundaries; use kebab-case file names.

## Going deeper (optional, ADF's toolkit)

- Skills: `.claude/skills/<name>/SKILL.md` (also `.agents/skills` with `--codex`, `.agent/skills` with `--antigravity`). Agents: `.claude/agents/<name>.md` (Codex, with `--codex`: `.codex/agents/<name>.toml`). Antigravity slash commands, with `--antigravity`: `.agent/workflows/`. Full rule texts: `.claude/rules/*.md`.
- Python skill scripts: `.claude/skills/.venv/bin/python3 scripts/xxx.py` (Windows: `.claude\skills\.venv\Scripts\python.exe`). When one fails, report it; fix skill code only if the task allows.
- An update replaces edited ADF files (your copy goes to `.claude/backups/`). Give new skills and agents names ADF does not use.

### Outside Claude Code

ADF text is written for Claude Code. Elsewhere, read these names as:

- `AskUserQuestion`: ask in chat with numbered options and wait; when nobody can answer, follow the decide-and-record rule instead.
- `Agent` / `Task` with `subagent_type: <name>`: spawn a sub-agent with that role, or do the work inline following `.claude/agents/<name>.md`.
- `TaskCreate`, `TaskUpdate`, `SendMessage`, Teams (`/team`): not available; use your own todo list and work in sequence.
- `Skill(...)` or `/<skill>`: open `.claude/skills/<skill>/SKILL.md` and follow it.
- `$CLAUDE_PROJECT_DIR`: the repository root. Read, Write, Edit, Grep, Glob, Bash: your own file and shell tools.
<!-- <<< ADF <<< -->
