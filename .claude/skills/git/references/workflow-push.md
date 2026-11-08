# Push Workflow

Execute via `git-manager` subagent.

## Pre-Push Checklist
1. All changes committed
2. Secrets scanned (see `safety-protocols.md`)
3. Branch pushed to remote

## Tool 1: Verify State
```bash
git status && \
git log origin/$(git rev-parse --abbrev-ref HEAD)..HEAD --oneline 2>/dev/null || echo "NO_UPSTREAM"
```

**If uncommitted changes:** Warn user, suggest commit first.
**If NO_UPSTREAM:** Use `git push -u origin HEAD`.

## Tool 2: Push
```bash
git push origin HEAD
```

**On success:** Report commit hashes pushed. When the branch is new on the remote and is a `feat/`, `fix/` or `hotfix/` branch, open its PR now (`workflow-pr.md`).

A direct push to the main branch only carries `chore` commits on `git.directPush.paths` (`git-flow.cjs check-push --range origin/<main>..HEAD`). Anything else goes through a PR.

## Error Handling

| Error | Cause | Solution |
|-------|-------|----------|
| `rejected - non-fast-forward` | Remote has newer commits | `git pull --rebase`, resolve conflicts, push again |
| `no upstream branch` | Branch not tracked | `git push -u origin HEAD` |
| `Authentication failed` | Invalid credentials | Check `gh auth status` or SSH keys |
| `Repository not found` | Wrong remote URL | Verify `git remote -v` |
| `Permission denied` | No write access | Check repository permissions |

## Force Push (DANGER)

**Never force push the main branch or a `release/*` branch.** The `git-flow-guard` hook always denies it.

If the user explicitly asks to force push their own feature branch:
```bash
git push --force-with-lease origin HEAD
```

**Warn user:** "Force push rewrites history. Collaborators may lose work."

## Output Format
```
✓ pushed: N commits to origin/{branch}
  - abc123 feat(auth): add login
  - def456 fix(api): resolve timeout
```
