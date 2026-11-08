---
name: adf-mode
description: "Switch ADF between strict mode (every ask as configured) and auto mode (asks become allows, denies stay, Claude decides and records instead of asking), or show what each knob does now."
user-invocable: true
disable-model-invocation: true
when_to_use: "Invoke when the user wants Claude to run unattended (auto), wants the prompts back (strict), or asks why something did or did not ask (status)."
argument-hint: "auto|strict|status"
category: utilities
keywords: [mode, auto, strict, prompts, unattended, permissions, enforcement, ask]
metadata:
  author: adf
  version: "1.0.0"
---

# ADF mode

One switch for every place ADF asks. Run it as `node .claude/skills/adf-mode/scripts/adf-mode.cjs <command>` (also the entry on Windows); add `--json` for one JSON object, `--cwd <dir>` to act on another project.

| Command | Does | Writes |
|---|---|---|
| `auto` | Asks become allows, denies stay. `git.enforcement: ask` runs as `off` (a configured `deny` is kept); `privacy-block` lets its sensitive-path asks through (the `permissions.deny` rules still refuse secret files); the `ask-gate` hook refuses `AskUserQuestion` and tells Claude to choose by the stated principles, else the recommended option, and record it under "Decisions" in the plan; a commit that would record a secret is refused instead of asked; Claude Code's own prompts for unlisted commands and edits are off. | `mode: "auto"` in `.claude/config/adf-config.json` (plus `modeRestore` when a permission mode was already set); `permissions.defaultMode: "bypassPermissions"` in `.claude/settings.local.json` |
| `strict` | Restores every prompt. This is the shipped default. | Removes `mode`; puts back the remembered `permissions.defaultMode`, or removes `bypassPermissions` when nothing was remembered (and `settings.local.json` itself when nothing else is in it). A file that is not valid JSON is left alone with an error |
| `status` | Mode and its source (`ADF_MODE` env, config, default), then each knob: `git.enforcement` configured and effective, `privacy-block`, `ask-gate`, `permissions.defaultMode`, and what both modes keep. | nothing |

## Rules

1. The session prints `Mode: auto ...` at start while auto is on. In auto, when a skill reaches an `AskUserQuestion` gate, do not ask: choose by the stated principles (the brief's `## Principles`, then the plan's, then the project's conventions), else the recommended option (else the first, else the smallest answer that keeps the work moving), say so in the reply, and add it under a `## Decisions` heading in the active `plan.md` when a plan exists: one `### topic` with Chosen, Alternatives, Why and Review later (format in `../adf-plan/references/plan-contract.md`). The same rule applies whenever nobody can answer, in any mode (see "Modes" in `CLAUDE.md`).
2. Auto never weakens a deny: `permissions.deny` reads, the explicit `permissions.ask` rules for destructive commands (Claude Code prompts for those in every mode), the ban on force-pushing main and release branches and a configured `git.enforcement: deny` behave the same in both modes; the commit secret scan refuses in auto where it asked in strict. Destructive actions outside the repository (deleting remote branches others use, dropping databases) still deserve a sentence of warning in the reply before they run.
3. `ADF_MODE=auto` or `ADF_MODE=strict` in the environment overrides the file for one session; `status` shows it. It does not change `permissions.defaultMode`, so Claude Code's own prompts follow `settings.local.json`.
4. The mode is the one of the project Claude was launched in (`$CLAUDE_PROJECT_DIR`, else the nearest `.claude/`): in a workspace the root decides, a member's own config does not. The permission mode applies from the next Claude Code session; the ADF hooks read the mode on every call, so `auto` and `strict` take effect at once for them.
5. `adf-config.json` is usually committed, so `mode: "auto"` reaches everyone who pulls it; set it for a team only when the team agreed. In the ADF repository itself `adf-config.json` and `settings.local.json` are local-only files: never stage what this command writes there.
