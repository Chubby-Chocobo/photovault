# GitHub CLI Guide

## Authentication
```bash
gh auth login        # Interactive login
gh auth status       # Check auth state
gh auth logout       # Logout
```

## Pull Requests

### Create PR
Always set `--base` from the flow. `pr-target` exits non-zero when no release is open (stop and suggest `/git release cut`); `&&` keeps `gh` from falling back to main. Add `--head <branch>` to `pr-target` when the head is not the current branch.
```bash
# Basic
BASE=$(node .claude/skills/git/scripts/git-flow.cjs pr-target) && \
gh pr create --base "$BASE" --head feature-branch --title "feat: add login" --body "Summary"

# With HEREDOC body
gh pr create --base "$BASE" --title "feat(auth): add OAuth" --body "$(cat <<'EOF'
## Summary
- Added OAuth2 provider support
- Implemented token refresh

## Test plan
- [ ] Unit tests pass
- [ ] Manual login test
EOF
)"

# Draft mode
gh pr create --draft --base "$BASE" --title "WIP: new feature"

# Assign reviewers
gh pr create --base "$BASE" --reviewer @user1,@user2

# Add labels
gh pr create --base "$BASE" --label "bug,priority:high"
```

### View/Review PR
```bash
gh pr list                    # List PRs
gh pr view 123                # View PR details
gh pr view 123 --web          # Open in browser
gh pr checkout 123            # Checkout PR locally
gh pr diff 123                # View PR diff
gh pr status                  # Your PRs + reviews
```

### Merge PR
```bash
gh pr merge 123 --merge       # Merge commit (release into main, back-merges)
gh pr merge 123 --squash      # Squash commits
gh pr merge 123 --rebase      # Rebase merge
gh pr merge 123 --delete-branch  # Delete branch after
```

### PR Comments
```bash
gh pr comment 123 --body "LGTM!"
gh api repos/{owner}/{repo}/pulls/123/comments  # View all
```

## Issues

```bash
gh issue list                 # List issues
gh issue view 42              # View issue
gh issue create --title "Bug" --body "Description"
gh issue develop 42 -c        # Create branch from issue
```

## Repository

```bash
gh repo view                  # Current repo info
gh repo clone owner/repo      # Clone
gh browse                     # Open repo in browser
gh browse path/to/file:42     # Open file at line
```

## Workflow Runs

```bash
gh run list                   # List workflow runs
gh run view <run-id>          # View run details
gh run watch                  # Watch running workflow
gh run rerun <run-id>         # Rerun failed workflow
```

## JSON Output (scripting)

```bash
gh pr list --json number,title,author
gh pr view 123 --json commits,reviews
gh issue list --json number,title --jq '.[].title'
```

## Common Patterns

### Merge with the flow's strategy
Take the strategy from `git-flow.cjs check-pr` (`squash` or `merge`), pass it explicitly, and only with the user's go-ahead. Never use `--auto`: without branch protection it merges at once, green or not.
```bash
gh pr merge 123 --squash --delete-branch
```

### Close one PR
Close PRs one at a time after confirming each with the user; never close a list in bulk.
```bash
gh pr close 123 --comment "Superseded by #130"
```
