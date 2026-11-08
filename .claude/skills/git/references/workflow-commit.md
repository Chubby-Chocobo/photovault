# Commit Workflow

Execute via `git-manager` subagent.

## Tool 1: Stage + Analyze

Stage the files this change owns, by name. Never `git add -A`, `git add .` or `git commit -a`; leave unrelated changes alone.

```bash
git status --short && \
git add -- <path> <path> ... && \
echo "=== STAGED ===" && git diff --cached --stat && \
echo "=== GROUPS ===" && \
git diff --cached --name-only | awk -F'/' '{
  if ($0 ~ /\.(md|txt)$/) print "docs:"$0
  else if ($0 ~ /test|spec/) print "test:"$0
  else if ($0 ~ /\.claude/) print "config:"$0
  else if ($0 ~ /package\.json|lock/) print "deps:"$0
  else print "code:"$0
}'
```

Secret check, by value and not by word (`token` or `password` alone is not a finding): in Claude Code the `commit-guard` hook asks on real credential formats. Outside Claude Code (Codex, Antigravity, other agents), run the scan in `safety-protocols.md` on the staged diff unless the user installed the native pre-commit hook, which refuses on the same formats. On a match or a refusal, stop and tell the user: the remedies are a person's.

## Tool 2: Split Decision

NOTE:
- Search for related issues on GitHub and add to body.
- If `git.commit.pathTypes` in `.claude/config/adf-config.json` limits the types for a folder, use one of those for files under it; the `commit-guard` hook names them when a type is not allowed.

**From groups, decide:**

**A) Single commit:** Same type/scope, FILES ≤ 3, LINES ≤ 50

**B) Multi commit:** Mixed types/scopes, group by:
- Group 1: `config:` → `chore(config): ...` (or a type `git.commit.pathTypes` allows there)
- Group 2: `deps:` → `chore(deps): ...`
- Group 3: `test:` → `test: ...`
- Group 4: `code:` → `feat|fix: ...`
- Group 5: `docs:` → `docs: ...`

## Tool 3: Commit

**Single:**
```bash
git commit -m "type(scope): description"
```

**Multi (sequential):**
```bash
git restore --staged -- . && git add -- file1 file2 && git commit -m "type(scope): desc"
```
Repeat for each group.

## Tool 4: Push (if requested)
```bash
git push && echo "✓ pushed: yes" || echo "✓ pushed: no"
```

**Only push if user explicitly requested** ("push", "commit and push").
