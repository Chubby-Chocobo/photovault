# CI templates for the git workflow

`git-flow.cjs setup-ci` copies `adf-git-guards.yml` to `.github/workflows/` once, with the project's main branch filled in. After that the file belongs to the project; `setup-ci --check` says when ADF's template has changed since the copy, and never overwrites.

## Jobs

| Event | Job | What it does |
|---|---|---|
| PR into main | `guard-main-pr` | `check-pr`: the head fits the flow; a release or hotfix head carries the version the merge will tag; a release branch contains all of main |
| Push to main | `guard-main-push` | `check-push`: a direct push carries only `chore` commits on `git.directPush.paths` (merged PRs are skipped) |
| Push to main | `verify` | placeholder: replace with the project's tests, lint and build |
| Push to main | `tag-release` | after the checks pass, tags `vX.Y.Z` from the merged branch and publishes the GitHub release; refuses a merge that broke the flow |

PRs into release branches run nothing here: test them locally, or add a workflow of your own.

## How much this guarantees

| Setup | A bad PR into main | A bad merge |
|---|---|---|
| Branch protection with `guard-main-pr` and `verify` required | cannot merge | cannot happen |
| No branch protection (private repos on GitHub Free) | the check is red, but the merge button still works | `tag-release` fails and tags nothing; the Claude Code hooks and the optional native pre-push hook catch most mistakes earlier |

So on GitHub Free, a red check is the enforcement: retarget or fix, never merge over it. Never use `gh pr merge --auto` there; it merges at once.

## A missing tag

Each push to main runs in its own concurrency group, so a queued tag run is never dropped for a later push, and `tag-release` is safe to run twice. If a tag or GitHub release is still missing (a failed run, a cancelled one), re-run the workflow for that merge commit, or run `git-flow.cjs tag-release --sha <merge>` locally. A re-run finds the existing tag and publishes the release if it is missing.

## Permissions

`tag-release` needs `contents: write` and `pull-requests: read` (to find the merged PR), which the job asks for. When the PR lookup fails, the job fails instead of leaving a hotfix untagged. If the organization sets Actions to read-only, allow write access for this repository (Settings → Actions → General → Workflow permissions), or keep the default read-only and grant it per job as the template does.

## Deploy and migrate

- Put deploy and migrate jobs in this same workflow with `needs: tag-release`, and read the tag from `needs.tag-release.outputs.tag`. Order: checks, then migrate, then tag, then deploy; or checks, then tag, then deploy. Never tag before the checks are green.
- Tags pushed with `GITHUB_TOKEN` do not start other workflows. If you deploy from an `on: push: tags` workflow, have `tag-release` push the tag with a GitHub App token instead (`actions/create-github-app-token`, then pass it as `GH_TOKEN` and set the remote URL with it).

## Other CI systems

The scripts are CI-agnostic. With full history and tags fetched, run:

```bash
node .claude/skills/git/scripts/git-flow.cjs check-pr --base main --head "$SOURCE_BRANCH"       # on merge requests into main
node .claude/skills/git/scripts/git-flow.cjs check-push --range "$BEFORE..$AFTER"               # on direct pushes to main only
node .claude/skills/git/scripts/git-flow.cjs tag-release --sha "$COMMIT" --head "$SOURCE_BRANCH" --no-gh   # after the checks, on merges into main
```

Run `check-push` only for pushes that did not come from a merge request: a release merge carries feature commits and would fail it. Without the GitHub CLI, pass `--head` (the merged branch) and `--no-gh` to `tag-release`, since it cannot look the merge request up.
