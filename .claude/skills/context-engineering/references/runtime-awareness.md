# Runtime Awareness

Monitor usage limits and context window utilization to optimize Claude Code sessions.

## Overview

1. **Usage Limits** - subscription quota consumption (5-hour and 7-day rolling windows)
2. **Context Window** - current token utilization within the model's context limit

Both are displayed by `.claude/statusline.cjs`. No hook fetches or injects them, and nothing reads credentials: Claude Code hands the statusline everything on stdin.

## Usage Limits (statusline stdin)

Claude Code passes the statusline command a JSON document on stdin. For claude.ai Pro/Max subscribers it includes, after the first API response of a session:

```json
{
  "rate_limits": {
    "five_hour": { "used_percentage": 42, "resets_at": 1767225600 },
    "seven_day": { "used_percentage": 10, "resets_at": 1767744000 }
  }
}
```

- `used_percentage`: 0-100
- `resets_at`: Unix epoch **seconds**
- Each window may be absent independently; `rate_limits` is absent entirely for API-key and third-party-provider sessions. The statusline then hides the chip (`5h NN% (countdown)` / `wk NN% (countdown)`).
- Hide the chips for good with `"statuslineQuota": false` in `adf-config.json`.
- Reference: https://code.claude.com/docs/en/statusline

## Context Window Data

The statusline also persists context data to `/tmp/adf-context-{session_id}.json` for other tools:

```json
{
  "percent": 67,
  "tokens": 134000,
  "size": 200000,
  "usage": {
    "input_tokens": 80000,
    "cache_creation_input_tokens": 30000,
    "cache_read_input_tokens": 24000
  },
  "timestamp": 1705312000000
}
```

Token calculation (when Claude Code does not supply `context_window.used_percentage`):

```
total = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
percent = (total + AUTOCOMPACT_BUFFER) / context_window_size * 100
```

Where `AUTOCOMPACT_BUFFER = 40000`.

## Recommendations by Threshold

### Context Window

| Utilization | Action |
|-------------|--------|
| < 70% | Continue normally |
| 70-80% | Plan compaction strategy |
| 80-90% | Execute compaction |
| > 90% | Immediate compaction or session reset |

### Usage Limits

| 5-Hour | Action |
|--------|--------|
| < 70% | Normal usage |
| 70-90% | Reduce parallelization, delegate to subagents |
| > 90% | Wait for reset or use lower-tier models |

| 7-Day | Action |
|-------|--------|
| < 70% | Normal usage |
| 70-90% | Monitor daily consumption |
| > 90% | Limit usage to essential tasks |

## Configuration

Only the statusline needs to be registered in `.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "node \"${CLAUDE_PROJECT_DIR:-.}/.claude/statusline.cjs\""
  }
}
```

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| No usage limits shown | Not a claude.ai Pro/Max session, or no API response yet | Expected; chips appear after the first response |
| Only one window shown | Claude Code omitted the other window | Expected |
| Stale context data | Statusline not updating | Check statusline config |
