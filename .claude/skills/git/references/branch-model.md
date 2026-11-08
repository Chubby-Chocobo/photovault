# Branch Model

The flow is `git.flow` in `.claude/config/adf-config.json`. Ask the script instead of working it out:

```bash
node .claude/skills/git/scripts/git-flow.cjs status           # flow, active release, PR target, merge strategy
node .claude/skills/git/scripts/git-flow.cjs active-release   # release/x.y.z on the remote with no tag yet
```

## `release-train` (default)

| Branch | Cut from | PR into | Merge |
|---|---|---|---|
| `release/x.y.z` | main | main | merge commit |
| `feat/<name>`, `fix/<issue>` | the active release | the active release | squash |
| `hotfix/<issue>` | main | main | squash |

- Only release and hotfix branches open PRs into main.
- One release is open at a time.
- After the release PR opens, bug fixes for that release (only fixes) may be committed straight onto the release branch. Check first that the PR is open: `gh pr list --state open --base <main>`.

## `trunk`

- `feat/*`, `fix/*` and `hotfix/*` squash into main.
- `cut-release` makes a short `release/x.y.z` with only the bump and changelog, which squashes into main.

## `off`

No branch-model checks. Commit format, explicit staging, secrets and the force-push ban on protected branches still apply.

## Naming

`feat/`, `fix/`, `hotfix/` and `release/` are fixed; other prefixes (`chore/`, `docs/`, `refactor/`) are fine for work that is not a feature or a fix and follow the feature rules.

## Starting a branch

```bash
git fetch origin
TARGET=$(node .claude/skills/git/scripts/git-flow.cjs pr-target --head feat/<name>)
git checkout -b feat/<name> "origin/$TARGET"
# first commit, then at once:
git push -u origin feat/<name>
gh pr create --base "$TARGET" --draft --title "feat(scope): ..." --body "..."
```

Protected branches are the main branch and every `release/*`: never force-push or delete them by hand.
