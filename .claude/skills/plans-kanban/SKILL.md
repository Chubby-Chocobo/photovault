---
name: plans-kanban
description: View plans dashboard with progress tracking and timeline visualization. Use for kanban boards, plan status overview, phase progress, milestone tracking, project visibility.
user-invocable: true
disable-model-invocation: true
when_to_use: "Invoke to open or inspect the plans dashboard."
category: dev-tools
keywords: [plans, dashboard, kanban, progress, timeline]
argument-hint: "[plans-dir]"
metadata:
  author: adf
  version: "1.0.0"
---

# plans-kanban

Plans dashboard server with progress tracking and timeline visualization.

## ⚠️ Installation Required

**This skill requires npm dependencies.** Run one of the following:

```bash
# From the ADF clone (installs local skill dependencies into the project)
bash <adf-clone>/install.sh <project> --skill-deps
# Or, from inside the project, local dependencies only
bash .claude/skills/install.sh --local-only
# Or manually:
cd .claude/skills/plans-kanban && npm install
```

**Dependencies:** `gray-matter`

Without installation the server crashes at startup with `Cannot find module 'gray-matter'` (not an HTTP 500). Install, then start it again.

Never run `bash .claude/skills/install.sh` without `--local-only`; it installs system packages and touches files outside the project.

## Purpose

Visual dashboard for viewing plan directories with:
- Progress tracking per plan
- Timeline/Gantt visualization
- Phase status indicators
- Activity heatmap

## Quick Start

```bash
# View plans dashboard
node .claude/skills/plans-kanban/scripts/server.cjs \
  --dir ./plans \
  --open

# Remote access: explicit opt-in only, exposes plans to the LAN (see Remote Access)
# node .claude/skills/plans-kanban/scripts/server.cjs --dir ./plans --host 0.0.0.0

# Background mode
node .claude/skills/plans-kanban/scripts/server.cjs \
  --dir ./plans \
  --background

# Stop all running servers
node .claude/skills/plans-kanban/scripts/server.cjs --stop
```

## Slash Command

Use `/plans-kanban` for quick access:

```bash
/plans-kanban plans/           # View plans dashboard
/plans-kanban --stop           # Stop kanban server
```

## Features

### Dashboard View
- Plan cards with progress bars
- Phase status breakdown (completed, in-progress, pending)
- Last modified timestamps
- Issue and branch links
- Priority indicators

### Timeline Visualization
- Gantt-style timeline of plans
- Duration tracking
- Activity heatmap

### Design
- Glassmorphism UI with dark mode
- Responsive grid layout
- Warm accent colors

## CLI Options

| Option | Description | Default |
|--------|-------------|---------|
| `--dir <path>` | Plans directory | - |
| `--port <number>` | Server port (any 1-65535; auto-search 3500-3550 when omitted or busy) | 3500 |
| `--host <addr>` | Host to bind (non-loopback exposes to LAN, prints warning) | 127.0.0.1 |
| `--open` | Auto-open browser | false |
| `--background` | Run in background | false |
| `--stop` | Stop all servers | - |

## Architecture

```
scripts/
├── server.cjs               # Main entry point
└── lib/
    ├── port-finder.cjs      # Port allocation (3500-3550)
    ├── process-mgr.cjs      # PID management
    ├── http-server.cjs      # HTTP routing
    ├── plan-parser.cjs      # Plan.md parsing
    ├── plan-scanner.cjs     # Directory scanning
    ├── plan-metadata-extractor.cjs  # Rich metadata
    └── dashboard-renderer.cjs       # HTML generation

assets/
├── dashboard-template.html  # Dashboard HTML template
├── dashboard.css           # Styles
└── dashboard.js            # Client interactivity
```

## HTTP Routes

| Route | Description |
|-------|-------------|
| `/` or `/kanban` | Dashboard view |
| `/kanban?dir=<path>` | Dashboard for specific directory |
| `/api/plans` | JSON API for plans data |
| `/api/plans?dir=<path>` | JSON API for specific directory |
| `/assets/*` | Static assets |
| `/file/*` | Local file serving |

## Remote Access

**Security:** Binds to `127.0.0.1` by default and rejects non-loopback Host headers. `--host 0.0.0.0` is an explicit opt-in that exposes the served files to your LAN with no authentication (a warning is printed); do not use it unless the user asks. Only the plans dir and dashboard assets are served; dotfiles are refused.

When using `--host 0.0.0.0`, the server auto-detects your local network IP:

```json
{
  "success": true,
  "url": "http://localhost:3500/kanban?dir=...",
  "networkUrl": "http://192.168.2.75:3500/kanban?dir=...",
  "port": 3500
}
```

Use `networkUrl` to access from other devices on the same network.

## Plan Link Text

The dashboard shows each phase using the link text from the `plan.md` phases table.
Link text must be a human-readable name, never the filename. The `plan-format-kanban` hook warns on filename link text.

```markdown
Bad:  [phase-01-setup.md](./phase-01-setup.md)
Good: [Setup Environment](./phase-01-setup.md)
```

## Plan Structure

The dashboard scans for directories containing `plan.md` files:

```
plans/
├── 251215-feature-a/
│   ├── plan.md              # Required - parsed for phases
│   ├── phase-01-setup.md
│   └── phase-02-impl.md
├── 251214-feature-b/
│   └── plan.md
└── templates/               # Excluded by default
```

## Troubleshooting

**Port in use**: Server auto-increments from 3500-3550

**No plans found**: Ensure directories contain `plan.md` files

**Remote access denied**: Default bind is loopback only. Only if the user explicitly wants LAN access, pass `--host 0.0.0.0` (see the Remote Access warning)

**PID files**: Located at `/tmp/plans-kanban-*.pid`
