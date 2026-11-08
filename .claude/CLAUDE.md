<!-- adf:managed - written by ADF install.sh; local edits are backed up on update -->
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Role

Analyze the user's requirements, pick the lightest workflow that delivers them, and make sure the result meets the spec and the project's architecture. Delegate to subagents when the work is broad, parallel, or would flood the main context with file dumps; do small, focused work directly.

## Rules and workflows

The rule files in `./.claude/rules/` load automatically at session start; follow them:

- `primary-workflow.md`: implementation flow and delegation order
- `development-rules.md`: code, test and commit conventions
- `orchestration-protocol.md`: how to brief and coordinate subagents
- `documentation-management.md`: plans, estimates and `./docs` upkeep
- `review-audit-self-decision.md`: handling review findings and user decisions

Before planning or implementing, read `./README.md` for project context. Check the skills catalog and activate the skills that fit the task.

Reports go in `plans/reports/`. Keep them short and list unresolved questions at the end.

## Output styles

`./.claude/output-styles/coding-level-{0..5}-*.md` set explanation depth (0 = ELI5 … 5 = expert). Pick one with `/output-style` or the `/coding-level` skill. Nothing is injected automatically.

## Secret files

Settings deny reading `.env` variants, private keys (`*.pem`, `*.key`, `id_rsa`, `id_ed25519`) and `secrets.y(a)ml`. The privacy hook makes Claude Code ask the user before any other tool call that touches a sensitive path: credentials files, `.mcp.json`, `~/.ssh`, `~/.aws`, the key and secret files above and `.env` variants, whether the tool is Read, Edit, Write or a Bash command that names the path (`cat`, `cp`, a glob such as `.env*`). Code that reads `process.env.X` and searches that only use such words as a pattern (`grep -rn process.env src`, `jq .key a.json`) do not trigger it; the files they search still do. The hook reads the deny rules from the project's `.claude/settings.json` and `settings.local.json`; where a rule no longer covers a Read, the ask comes back. When the user approves, use the file as needed but never echo secret values into the conversation, logs or commits. `.env.example` and other templates are always readable.

Destructive commands (`rm -rf`, `git reset --hard`, `git clean`, force push, `git branch -D`, `DROP`/`TRUNCATE`) ask the user first. If the user declines, do not reach the same result with a different command; ask how to proceed. Never use `--no-verify` on `git commit` or `git push` (nor `-n` on `git commit`) unless the user says so. When a hook refuses a commit or push, stop and tell the user; never add `adf-allow-secret` or change `commitGuard` settings unless the user says so.

## Modes

`/adf-mode auto|strict|status` switches ADF's asks at once. In auto (the session starts with a `Mode: auto` line) an ask becomes an allow and a deny stays a deny: do not call `AskUserQuestion`; decide and record as the next sentence says. When nobody can answer (auto mode, a non-interactive run such as `claude -p` or `codex exec`, a prompt that says it runs unattended, or `AskUserQuestion` unavailable or denied), never wait: choose by the stated principles (the brief's `## Principles`, then the plan's, then the project's conventions), else the recommended option; say so and record it under `## Decisions` in the active plan (format in `.claude/skills/adf-plan/references/plan-contract.md`), or where the task says, or in the final reply when there is no plan; stop and report only when every option breaks a stated principle or a required input cannot be read. The explicit ask rules for destructive commands, the deny rules and the force-push ban still apply, and a commit that would record a secret is refused instead of asked. Strict is the default and what the two paragraphs above describe.

## Python scripts (skills)

Run Python scripts from `.claude/skills/` with the venv interpreter so packages installed by `install.sh` are available:
- Linux/macOS: `.claude/skills/.venv/bin/python3 scripts/xxx.py`
- Windows: `.claude\skills\.venv\Scripts\python.exe scripts\xxx.py`

When a skill script fails, report the failure. Fix the skill code and rerun only when the current task authorizes changing skills.

## Modularization

- When a code file grows past about 200 lines, consider splitting it along real boundaries (functions, classes, concerns). Check existing modules first.
- Use kebab-case file names that describe the content, even if long, so Grep and Glob find them.
- Skip this for Markdown, plain text, shell scripts, config and env files.

## Documentation

`./docs` (`paths.docs`) is the project's living truth: when something there stops being true, fix it. Dated working material (plans, reports, research, journals) goes in `./plans` instead. Create a folder only when it has content; a small project may only have `architecture/` and `conventions/`.

```
./docs
├── README.md        # map of the folders below (seeded by the installer)
├── requirements/    # What, for whom, why: prd.md, srs.md, brd.md (optional), roadmap.md, usecases/
├── design/          # What the user sees: design-system/, mockups/, wireframes/
├── architecture/    # How it is built: system-architecture.md, codebase-summary.md, decisions/
├── testing/         # How we know it works: testcases/, test-summary.md, exports/
├── conventions/     # How the team and agents work: code-standards.md, git-workflow.md, deployment.md
└── guides/          # How users of the product use it
```

Files in `docs/conventions/` are listed at session start with their descriptions; read the one a task needs before doing it.

## Project customization

In a project that has `.claude/.adf-manifest`, `install.sh` owns every file that manifest lists, and an update may replace any file you edited: an edit is kept until ADF's version of that file changes, then your copy goes to `.claude/backups/` and ADF's replaces it. When the user asks to add or change a rule, workflow, skill or agent for this project:
- Put project rules and processes in `docs/conventions/<topic>.md`, starting with front matter that has a one-line `description`. Short always-on notes may also go in the root `CLAUDE.md`. Older projects may still have `.claude/rules/project-*.md`; they keep loading in every session. `/docs migrate` with `--include-rules` moves them into `docs/conventions/`, after which they are listed as conventions and read when a task needs them rather than loaded every time; keep any rule that must always apply in the root `CLAUDE.md`.
- Give a new skill or agent a name ADF does not use.
- Leave ADF's own files unchanged.

ADF settings belong in `.claude/config/adf-config.json`, project hooks and permissions in `.claude/settings.json`; both are the project's and are never overwritten. Files the installer seeds into `docs/` (from `.claude/templates/docs/`) are the project's too: an update never overwrites them and only notes when ADF's template changed.
