# Pull Request Workflow

Execute via `git-manager` subagent.

## Variables
- TO_BRANCH: target. Default: the target `node .claude/skills/git/scripts/git-flow.cjs status` prints (the active release for `feat/*`/`fix/*` in a release train, the main branch for release and hotfix branches and in trunk).
- FROM_BRANCH: source (defaults to current branch)

## Open it early
Open the PR as soon as the branch has its first commit, as a draft (`--draft`) while work continues, and mark it ready (`gh pr ready`) when done. Before opening, run `git-flow.cjs check-pr --base $BASE --head $HEAD`; if it fails, fix the target or the branch instead of opening a PR the guard will reject.

## Use the remote diff
PRs based on remote branches. Local diff includes unpushed changes.

## Tool 1: Sync + Analyze

Bring the target into the branch first when it moved (for a release head, `git-flow.cjs back-merge`), so the diff and conflicts reflect what will land.

```bash
git fetch origin && \
git push -u origin HEAD 2>/dev/null || true && \
BASE=${BASE_BRANCH:-$(node .claude/skills/git/scripts/git-flow.cjs pr-target)} && \
HEAD=$(git rev-parse --abbrev-ref HEAD) && \
echo "=== PR: $HEAD → $BASE ===" && \
echo "=== COMMITS ===" && \
git log origin/$BASE...origin/$HEAD --oneline && \
echo "=== FILES ===" && \
git diff origin/$BASE...origin/$HEAD --stat
```

**If "Branch not on remote":** Push first, retry.

## Tool 2: Generate Content
**Title:** Conventional commit format, <72 chars, NO version numbers
**Body:** Summary bullets + Test plan checklist

## Tool 3: Create PR
```bash
gh pr create --draft --base $BASE --head $HEAD --title "..." --body "$(cat <<'EOF'
## Summary
- Bullet points

## Test plan
- [ ] Test item
EOF
)"
```

## do not use (local comparison)
- ❌ `git diff main...HEAD`
- ❌ `git diff --cached`
- ❌ `git status`

## Error Handling

| Error | Action |
|-------|--------|
| Branch not on remote | `git push -u origin HEAD`, retry |
| Empty diff | Warn: "No changes for PR" |
| Push rejected | `git pull --rebase`, resolve, push |
| No upstream | `git push -u origin HEAD` |
