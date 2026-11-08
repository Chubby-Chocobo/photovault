---
description: Branch model, merge rules, releases, hotfixes, versions and commit rules for this repo
---

# Git workflow

This is how the team and its agents use git here. The machine-checked values live in the `git` section of `.claude/config/adf-config.json`; the settings block below shows them as text, for agents that cannot run scripts. The installer writes that block and refreshes it only when it runs. This document says what the values mean and adds the process rules no script can check. When the two disagree, fix whichever is wrong in the same change.

For the live state (flow, active release, where the current branch's pull request goes and how it merges), run:

```bash
node .claude/skills/git/scripts/git-flow.cjs status
```

<!-- adf:git-settings begin -->
<!-- adf:git-settings v=1 hash=e98504dc17c9022d -->
## This project's settings

Written by the ADF installer from the `git` section of `.claude/config/adf-config.json`. Re-run the installer after you change the `git` settings or the workspace members. If you edit the lines between the markers, the installer stops refreshing them.

- Flow: `release-train` (pull requests and merges: its table under "Branch model")
- Main branch: `main`
- Enforcement: `ask`
- Release tags: `vx.y.z`
- Active release without node: the `release/*` branch on your remote (usually `origin`; `git remote` lists them) with no matching `vx.y.z` tag: `git ls-remote --heads <remote> 'release/*'`, then `git tag -l 'v*'`
- Direct pushes to `main`: `chore` commits touching only `docs/**`, `.github/**`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md`
- Version files: `package.json`
<!-- adf:git-settings end -->

## Branch model

The flow is set by `git.flow`. The default is `release-train`.

### `release-train`

| Branch | Name | Cut from | Merges into | Merge |
|---|---|---|---|---|
| Main | the `git.mainBranch` | | | |
| Release | `release/x.y.z` | main | main | **merge commit** |
| Feature | `feat/<name>` | the active release | the active release | squash |
| Fix | `fix/<issue>` | the active release | the active release | squash |
| Hotfix | `hotfix/<issue>` | main | main | squash |

- A release is never squashed into main. A squash forks main from the release line, so every later release replays old diffs.
- Features and fixes are squashed into the release, so one commit per change makes a scope cut a clean revert.
- The **active release** is the `release/*` branch on the remote that has no matching version tag. `git-flow.cjs active-release` prints it.

### `trunk`

- `feat/*`, `fix/*` and `hotfix/*` squash straight into main.
- A release is a short `release/x.y.z` branch made by `cut-release`, holding only the version bump and the changelog. It squashes into main, and CI tags it like any release.

### `off`

No branch-model checks. Commit-message checks, explicit staging, secret checks and the ban on force-pushing main still apply.

## Rules

1. **Only `release/*` and `hotfix/*` open pull requests into main** (release-train). Features and fixes go through the active release.
2. **Merge with the flow's strategy:** see the tables above. `git-flow.cjs status` prints the one for the current branch.
3. **Back-merge after every hotfix.** As soon as a hotfix lands on main, run `git-flow.cjs back-merge` on the active release. The version files keep the release's version but take the hotfix's other changes, `CHANGELOG.md` keeps both sides, and any other conflict stops the merge. A release that is behind main cannot open its pull request into main.
4. **Direct pushes to main** carry only `chore` commits that touch only `git.directPush.paths`. Everything else rides a release or a hotfix.
5. **One release at a time.** Cut the next release only after the current one has merged or been abandoned. Keep stabilization short.
6. **Open the pull request as soon as the branch has its first commit**, as a draft while the work is in progress. The pull request records which release the change ships in, and it is where review happens. Never merge a change that skipped its pull request.
7. **Once the release pull request is open, bug fixes for that release (and only bug fixes) may be committed straight onto the release branch.** Check that the pull request is open before you do it (`gh pr list --state open`). Features never qualify. Before the release pull request exists, a fix rides a `fix/*` pull request as usual.

## Release lifecycle

1. **Cut:** `git-flow.cjs cut-release x.y.z`. It creates `release/x.y.z` on the remote from the remote main, without touching your working tree, and commits the version bump there. Pick a minor version normally and a major one for breaking changes. It refuses a used version, a version older than the latest release, and a second open release. Running it again is safe.
2. **Develop:** branch `feat/*` and `fix/*` from the release, and open each pull request into it at the first commit.
3. **Test** on the release branch the way this project tests (see "Project-specific duties").
4. **Scope cut** if needed: revert the feature's squash commit on the release branch.
5. **Ship:**
   - Run `git-flow.cjs changelog --write` on the release branch and commit it.
   - Open the pull request `release/x.y.z → main`, wait for green checks, and merge it with a **merge commit**.
   - CI tags `vx.y.z` from the branch name.
   - Confirm the tag exists (`git fetch --tags`).
6. **Clean up:** retarget any pull request based on the release branch first, then delete the branch.

## Hotfix lifecycle

1. Branch `hotfix/<issue>` from the remote main and make the fix.
2. Run `git-flow.cjs bump-version --branch`, and commit the version change with the fix.
3. Open the pull request into main. CI must be green. Squash-merge it.
4. CI tags the newest version's patch plus one.
5. Back-merge main into the active release at once (rule 3).

The hotfix version comes from the newest tag when you bump. If another release or hotfix lands first, bump again and push before merging.

## Versions and tags

- The tag is the source of truth, and the files in `git.versionFiles` must agree with it.
- **Who sets the version:**

  | Case | Command |
  |---|---|
  | Release | `cut-release` commits the bump |
  | Hotfix | `bump-version --branch`, committed with the fix |
  | Explicitly | `bump-version x.y.z` |
  | Check only | `bump-version --check x.y.z` |

- **Never create release tags by hand.** CI runs `git-flow.cjs tag-release` on every push to main:
  - a merged `release/x.y.z` gets `vx.y.z`;
  - a merged `hotfix/*` gets the newest version's patch plus one;
  - anything else gets no tag.

  The tagger checks the merge again first (head branch, merge strategy, committed version) and refuses to tag a merge that broke the flow.

## Commits

- **Format:** `type(scope): description`, in the imperative mood, under 72 characters, with no trailing period.
- **Types:** `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `style`, `build`, `ci`, `chore`, `revert`, or the project's commitlint list. `git.commit.pathTypes` can limit the types allowed under a folder.
- **Split commits** when types or unrelated scopes mix, or when config and code mix.
- **No AI references:** no "Generated with", no AI `Co-Authored-By`, no session links, in commits or pull request descriptions.
- **No unstable identifiers:** keep plan IDs, phase numbers, audit labels and session references out of commit messages, code comments, migration names and test names. Describe the behavior or the reason instead.
- Link related issues in the pull request body.

## Safety

- **Stage explicit paths.** Never use `git add -A`, `git add .` or `git commit -a`, because working output (plans, reports, local config) is one bulk add away from being committed.
- **Never commit** secrets, tokens, dotenv files, private keys, credentials or personal data.
- **Never force-push** main or a release branch. On a rejected push, pull and rebase your own branch; do not force.
- **Compare against the remote** (`git diff origin/main...origin/feat/x`), not against local state.
- **Leave unrelated working-tree changes alone.** They belong to whoever made them.
- **Use separate worktrees** for parallel write-heavy work, never two owners for the same files.

## Traps

- **Without branch protection, `gh pr merge --auto` merges at once.** That is the case on private repos with GitHub Free, where a red check also does not block the merge button. Wait for `gh pr checks` to pass, then merge.
- **Deleting a base branch closes every pull request based on it**, and a closed pull request cannot be retargeted. Retarget the children first.
- **A branch that is behind runs old scripts.** Back-merge before trusting a script's behavior on it.
- **Squashing a stacked branch can bring back files** the parent deleted. Check the diff before pushing.

## Project-specific duties

Fill this in with what this project adds to the steps above. For example:

- **Database migrations:** keep them additive and back-compatible, number them after the latest one on the release branch, and regenerate generated types in the same pull request.
- **Deploy order:** what deploys when main moves, and what must run first.
- **Extra direct-push carve-outs:** what they are, and why they are safe.

## Values checked automatically

| Rule | Config key | Checked by |
|---|---|---|
| Branch model, PR targets | `git.flow`, `git.mainBranch` | `git-flow-guard` hook (`gh pr create`), CI `check-pr` |
| Merge strategy, green checks, `--auto` | `git.flow` | `git-flow-guard` hook (`gh pr merge`), `tag-release` |
| Direct pushes to main | `git.directPush.paths` | `git-flow-guard` hook (`git push`), CI `check-push`, optional native pre-push hook |
| Versions agree with the release | `git.versionFiles`, `git.tagPrefix` | CI `check-pr`, `tag-release` |
| Commit format and types | `git.commit.pathTypes`, commitlint `type-enum` | `commit-guard` hook |
| Explicit staging | always on | `git-flow-guard` and `commit-guard` hooks |
| No staged secrets | `commitGuard.secrets` (on by default); `commitGuard.allowSecretFiles` (none by default; only a person adds entries); a line with `adf-allow-secret` is skipped | `commit-guard` hook, native pre-commit hook |
| No force push to main or `release/*` | always on | `git-flow-guard` hook (always denies), native pre-push hook |
| How strictly the hooks react | `git.enforcement` (`off`, `ask`, `deny`) | all of the above |

ADF's hooks are written for Claude Code. For commits and pushes made elsewhere, a person runs `git-flow.cjs install-git-hooks` once per clone (https://github.com/sotatek-dev/adf/blob/main/docs/guides/git-workflow.md); agents do not install hooks. The hooks run `node` on scripts from this work tree at every commit and push, so install them only in clones you trust. Grok Build also runs ADF's Claude Code hooks once you trust the repo, and they may fail open there: do not rely on them in Grok Build. CI is the backstop for everything else.
