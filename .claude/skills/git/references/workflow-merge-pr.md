# Merge PR Workflow

Run from the main session, not `git-manager`: Step 2 edits code and runs skills and subagents, which `git-manager` cannot do, and merging needs the user's go-ahead at that moment. Show the PR list and the strategy, and ask before the first merge. `git-manager` may only run the mechanical `gh` and `git` commands when told to.

## Variables
- PR_REFS: one or more PR numbers or GitHub PR URLs
- READY_LABEL: `ready to ship`

## Step 1: Parse and Inspect

Require at least one PR ref:

```bash
gh auth status
gh repo view --json nameWithOwner,defaultBranchRef
for pr in "$@"; do
  gh pr view "$pr" --json number,url,title,baseRefName,headRefName,mergeStateStatus,statusCheckRollup
done
```

If any PR ref is invalid, from another repo, closed, or not visible to `gh`, stop before reviewing or merging any PRs.

## Step 2: Review, Fix, Reply

For each PR, activate:

```bash
/review-pr <PR number or URL> --fix --reply
```

Do not label or merge until `review-pr` reports all of these:
- verdict is **Approve** or explicitly merge-ready
- no Critical or Important findings remain
- no merge conflicts remain
- required PR checks are terminal and green

If a PR still needs changes, stop the entire merge batch. Report:
- PR number/URL
- remaining findings or blockers
- exact failed checks or merge state, if any
- recommended next action

## Step 3: Apply Ready Label

Ensure the label exists, then apply it to each reviewed-ready PR:

```bash
gh label list --json name --jq '.[].name' | grep -Fx "ready to ship" >/dev/null \
  || gh label create "ready to ship" --color "0E8A16" --description "Reviewed and ready to merge"
gh pr edit "$PR_REF" --add-label "ready to ship"
```

If labeling fails for any reason other than an already-existing label, stop and report the exact `gh` error.

## Step 4: Merge

Merge reviewed-ready PRs one at a time in the order provided.

Before each merge:
- re-read `mergeStateStatus`, `baseRefName`, `headRefName` and `statusCheckRollup`
- wait until `gh pr checks "$PR_REF"` passes; do not merge over a red or pending check
- take the merge method from the flow, never from habit: `node .claude/skills/git/scripts/git-flow.cjs check-pr --base <base> --head <head> --json` prints `strategy` (`squash` or `merge`)
- retarget any open PR based on this PR's head branch before `--delete-branch` (deleting a base branch closes its child PRs)

Pass the method explicitly, so `gh` never prompts:

```bash
gh pr merge "$PR_REF" --delete-branch "--$STRATEGY"
```

Do not use `--auto`: on a repo without branch protection (GitHub Free private repos) it merges at once, green or not. The `git-flow-guard` hook denies it there.

Never force push. Never direct-push to protected target branches.

## Step 5: Watch Target-Branch CI

After each merge, capture the base branch and merge commit:

```bash
gh pr view "$PR_REF" --json baseRefName,mergeCommit
```

Watch CI/deploy workflows for that merge commit on the target branch:

```bash
gh run list --branch "$BASE_BRANCH" --commit "$MERGE_SHA" --json databaseId,status,conclusion,name,url
gh run watch "$RUN_ID" --exit-status
```

If no workflow appears immediately, poll briefly before deciding there are no workflows for the merge commit.

## Step 6: CI Failure Convergence

If target-branch CI fails:

1. Inspect failed logs:
   ```bash
   gh run view "$RUN_ID" --json status,conclusion,jobs
   gh run view "$RUN_ID" --job "$JOB_ID" --log
   ```
2. If the failure is transient infrastructure, rerun failed jobs once:
   ```bash
   gh run rerun "$RUN_ID" --failed
   ```
3. If the failure is deterministic and repo-fixable, activate:
   ```bash
   /fix --auto "Fix post-merge CI failure from git merge-pr: <workflow, run id, job id, command, exact error>"
   ```
4. Ship the follow-up fix through PR review/merge, then watch target-branch CI again.

Stop only when target-branch CI succeeds, an external blocker remains, or the same blocker survives 3 fix attempts.

## Output Format

```text
reviewed: PR #123 approve, CI green
labeled: PR #123 ready to ship
merged: PR #123 into dev (merge SHA abc123)
CI: green for abc123
```

If blocked:

```text
stopped: PR #123 not merge-ready
reason: <finding/check/merge blocker>
suggestion: <next action>
```
