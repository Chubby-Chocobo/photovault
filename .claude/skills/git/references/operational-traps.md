# Operational Traps

Seen in practice; each one has cost a release.

- **`gh pr merge --auto` merges at once without branch protection.** Private repos on GitHub Free have none, so there are no required checks to wait for and a red check does not block the merge button either. Poll `gh pr checks` and merge only when green. The `git-flow-guard` hook denies `--auto` in that case.
- **Deleting a base branch closes every PR based on it**, and a closed PR cannot be retargeted. Retarget children (`gh pr edit <n> --base <new>`) before `gh pr merge --delete-branch` or `git push origin --delete`.
- **A branch that is behind runs old scripts.** Back-merge before trusting a script's behavior on it.
- **Squashing a stacked branch can resurrect files** the parent deleted. Check `git diff origin/<base>...HEAD --stat` before pushing and `git rm` what came back.
- **A red check on main freezes more than one release.** Tagging and deploy jobs hang off the checks, so every later hotfix waits until main is green again.
- **Untracked working output is one bulk add away from a commit.** `plans/**/reports/` and similar are often tracked folders. Stage by name.
- **The hotfix version is read at bump time.** If another release or hotfix lands first, bump again.
