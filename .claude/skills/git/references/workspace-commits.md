# Commits and PRs across a workspace

Use this when the project root holds `adf-workspace.json`. The members are separate git repos, each with its own branch model, so one change becomes one commit (and one PR) per member, plus a workspace commit for plans, docs and the system map.

Which rules apply where:

- Inside a member, git hooks and `git-flow.cjs` use that member's rules: its own `.claude/config/adf-config.json`, else `members[].git` in `adf-workspace.json`, else flow `off` with enforcement `ask`. This holds whether the session started in the workspace or in the member. The session-start `Git workflow:` line names the source.
- The workspace repo keeps the rules in its own config. Its `git.directPush.paths` should allow `plans/**` and not `docs/**` or the manifest (`workspace.cjs check` warns).

## The loop

1. **See the state.** `node .claude/skills/workspace/scripts/workspace.cjs repos --json` lists the members in scope and the workspace. Narrow it with `--plan <dir>` (the plan's `scope`), `--paths a,b`, or `--changed` (only repos with changes).
2. **Pick the branch name once.** Use the same name in every member, for example `feat/login-fix`. Members whose flow is `off` may use it too.
3. **For each row with changes**, in `path`:
   ```bash
   git -C <path> switch -c <branch>          # or switch to it, if it exists
   git -C <path> add -- <file> <file> ...    # by name; never -A, ., or commit -a
   git -C <path> commit -m "type(scope): description"
   ```
   Review `git -C <path> diff --cached --stat` before each commit. The commit hook checks that member's rules and scans for secrets.
4. **Push and open PRs only when asked.** The base is the row's `prBase`:
   ```bash
   git -C <path> push -u origin <branch>
   gh pr create --base <prBase> --head <branch> --title "..." --body "..."   # run with cwd = <path>
   ```
   Do not use a base you guessed. If `prBase` looks wrong, run `git-flow.cjs status --cwd <path>` and report what it says.
5. **Link the PRs.** `workspace.cjs pr-links --branch <branch> --write` adds a "Related pull requests" block to each PR body (between `<!-- adf:related-prs begin -->` and `end`). It is safe to re-run. It refuses when a member has more than one open PR for the branch, and it ignores PRs from forks. Without `--write` it only lists.
6. **Workspace files last.** Plans, docs and the system map are committed in the workspace repo, separately, with the workspace's rules (plans may go straight to the main branch; docs go through a PR).

Stop and report when a hook asks or denies. Do not try the same change another way.

## Example `repos --json`

```json
{
  "ok": true,
  "source": "plan",
  "repos": [
    { "name": "gateway", "path": "services/gateway", "branch": "main", "staged": 0, "unstaged": 2, "untracked": 0, "upstream": "origin/main", "ahead": 0, "behind": 0, "prBase": "main", "hasOwnAdf": false },
    { "name": "order", "path": "services/order", "branch": "feat/login-fix", "staged": 1, "unstaged": 0, "untracked": 1, "upstream": null, "ahead": null, "behind": null, "prBase": "release/1.2.0", "hasOwnAdf": true },
    { "name": "workspace", "path": ".", "branch": "main", "staged": 0, "unstaged": 0, "untracked": 1, "upstream": "origin/main", "ahead": 0, "behind": 0, "prBase": "main", "hasOwnAdf": true }
  ],
  "notCloned": [],
  "dropped": 0
}
```

`prBase` comes from the member's flow (`git-flow.cjs pr-target`). When the flow is off or cannot answer (no open release), it falls back to the manifest `branch`, then to `origin/HEAD`, then to the configured main branch. `repos` reads local refs only, so it never waits on a remote: run `git fetch` in a member first when its open release may be new. With no network it still answers from the last fetch, and falls back as above when that is not enough. A member listed in `notCloned` is in scope but not on disk: run `workspace.cjs bootstrap` or leave it out.

## Not covered

PR hosts other than GitHub: `pr-links` reports a repo that `gh` cannot query as "no PR found". Link those PRs by hand.
