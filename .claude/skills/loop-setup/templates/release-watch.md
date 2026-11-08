<!-- adf-loop-template: release-watch -->
Watch the workflows that run on the default branch after a merge. Report only; do not edit, commit or push.

1. Get the default branch (`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`) and its
   latest commit from GitHub, not the local checkout: `gh api repos/{owner}/{repo}/commits/<branch> --jq .sha`.
2. List the runs for that commit: `gh run list --branch <branch> --commit <sha> --json databaseId,name,status,conclusion,url`.
   Runs still queued or in progress: say "<n> runs pending on <short sha>" and check again soon.
   No runs yet: say so and check again soon; still none after three checks: report "no workflow ran
   for <short sha>" and stop the loop. Never report success without at least one finished run.
3. A run failed: read its log (`gh run view <id> --log-failed`) and report the workflow, the failing step,
   the cause and a proposed fix. Stop the loop.
4. All runs succeeded: report it in one line. If a release workflow ran, include the release whose tag
   points at this commit (`gh release list --limit 5`, then `gh api repos/{owner}/{repo}/commits/<tag> --jq .sha` for each tag); say
   "no release for this commit" when none does. Stop the loop.
5. A newer commit appears on the default branch: watch that commit instead.
