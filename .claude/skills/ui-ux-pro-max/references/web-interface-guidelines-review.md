# Web Interface Guidelines Review

Use when asked to "review my UI", "check accessibility", "audit design", "review UX", or "check my site against best practices" for specific files.

## How It Works

1. Fetch the latest guidelines with WebFetch from:
   `https://raw.githubusercontent.com/vercel-labs/web-interface-guidelines/main/command.md`
   The fetched content contains all rules and the output format instructions.
2. Read the specified files (or ask the user which files/pattern to review if none given).
3. Check the files against every rule in the fetched guidelines.
4. Output findings in the terse `file:line` format the guidelines specify.

Complements the Quick Reference checklist in `SKILL.md` (offline, priority-ordered) with the upstream, always-current rule set.
