# Git Safety Protocols

## Secret Detection Patterns

### Scan Command
Match credential values, not words: a line that mentions `token` or `password` in ordinary auth code is not a finding. Run it before every commit made outside Claude Code (Codex, Antigravity, other agents) unless the user installed the native pre-commit hook (`git-flow.cjs install-git-hooks`, a person's step), which refuses on the same real formats; in Claude Code the `commit-guard` hook asks. When either refuses, stop and tell the user: the remedies are a person's.
```bash
git diff --cached | grep -iE "(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(mongodb|postgres|mysql|redis)://[^ :/]+:[^ @]+@|[A-Za-z_-]*(key|token|secret|passw(or)?d|pwd)[\"']?[ ]*[:=][ ]*[\"']?[A-Za-z0-9_/+=.-]{16,})"
```

### Patterns to Detect

| Category | Pattern | Example |
|----------|---------|---------|
| API Keys | `api[_-]?key`, `apiKey` | `API_KEY=abc123` |
| AWS | `AKIA[0-9A-Z]{16}` | `AKIAIOSFODNN7EXAMPLE` | <!-- adf-allow-secret -->
| Tokens | `token`, `auth_token`, `jwt` | `AUTH_TOKEN=xyz` |
| Passwords | `password`, `passwd`, `pwd` | `DB_PASSWORD=secret` |
| Private Keys | `-----BEGIN PRIVATE KEY-----` | PEM files | <!-- adf-allow-secret -->
| DB URLs | `mongodb://`, `postgres://`, `mysql://` | Connection strings |
| OAuth | `client_secret`, `oauth_token` | `CLIENT_SECRET=abc` |

### Files to Warn About
- `.env`, `.env.*` (except `.env.example`)
- `*.key`, `*.pem`, `*.p12`
- `credentials.json`, `secrets.json`
- `config/private.*`

### Action on Detection
1. **Stop the commit** until the user confirms
2. Show matching lines: `git diff --cached | grep -B2 -A2 <pattern>`
3. Suggest: "Add to .gitignore or use environment variables"
4. Offer to unstage: `git reset HEAD <file>`

## Branch Protection

### Never Force Push To
- the main branch (`git.mainBranch`) and every `release/*`. The `git-flow-guard` hook always denies it; never force-push from a teammate or subagent session at all.
- Never stage with `git add -A`, `git add .` or `git commit -a`; stage by name.
- Leave unrelated working-tree changes alone.

### Pre-Merge Checks
```bash
# Check for conflicts before merge
git merge --no-commit --no-ff origin/{branch} && git merge --abort
```

### Remote-First Operations
Always use `origin/{branch}` for comparisons:
- ✅ `git diff origin/main...origin/feature`
- ❌ `git diff main...HEAD` (includes local uncommitted)

## Error Recovery

### Undo Last Commit (unpushed)
```bash
git reset --soft HEAD~1  # Keep changes staged
git reset HEAD~1         # Keep changes unstaged
```

### Abort Merge
```bash
git merge --abort
```

### Discard Local Changes
```bash
git checkout -- <file>   # Single file
git reset --hard HEAD    # All files (DANGER)
```

**Always confirm with user before destructive operations.**
