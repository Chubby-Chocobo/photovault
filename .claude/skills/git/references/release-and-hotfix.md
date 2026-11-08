# Releases, Hotfixes, Versions and Tags

All steps call `node .claude/skills/git/scripts/git-flow.cjs` (below: `git-flow`). Every push, PR and merge needs the user's go-ahead at that moment, so run `release ship` and `merge-pr` from the main session, not a subagent; `git-manager` only does the mechanical commit, push and PR steps it is told to.

## `release cut <x.y.z>`

```bash
git-flow cut-release <x.y.z> --dry-run    # show the plan
git-flow cut-release <x.y.z>              # create release/x.y.z on the remote from its main, commit the bump
git-flow cut-release --next minor|patch --dry-run   # print the next version, change nothing
git-flow cut-release --next minor|patch   # same, with the version picked for you
```

- Minor normally, major for breaking changes.
- Refuses a used version, a version not newer than the last release, and a second open release.
- Leaves the working tree alone. Running it again is safe.
- In `trunk` it also writes the changelog section; open the release PR into main and squash it.

### `--next minor|patch`

- Takes the place of `<x.y.z>`; giving both is refused.
- The base is the newest of the tags on the remote that carry `git.tagPrefix` (other prefixes are ignored) and the version in the version files on `<remote>/<main>`. The files count because a release can be merged but not tagged yet, or its branch deleted on merge; the next cut must not reuse that version. The working tree is not read.
- `minor` gives `x.(y+1).0`, `patch` gives `x.y.(z+1)`. With no tag and no version in the files the result is `0.1.0`.
- `--dry-run` prints just the version (text), or the full result with `--json` (`version`, `branch`, `steps`).
- Refuses while any release is open (`release_open`). To finish a half-cut release, run `cut-release <x.y.z>` with its version.

### Half-cut and shipped branches

`cut-release <x.y.z>` on a branch that exists without its bump commit adds the bump (and, in `trunk`, the changelog section). It refuses a branch that already went into main (`already_shipped`): the head is an ancestor of `<remote>/<main>` and holds the cut's `chore(release): x.y.z` bump commit (a merge commit), or the version files on main hold the version but did not at the merge base (a squash merge). A main that already held the version before the branch was cut does not count, so rerunning stays safe. A shipped release only needs its tag; check the tagger.

Known limits:

- An explicit `cut-release <x.y.z>` is not compared with the version files on main, only with the tags (`--next` is). A hotfix merged but not yet tagged can be reused by an explicit version.
- Two `--next` runs at the same moment with different bumps can each pass the open-release check and open two releases; `active-release --json` shows it. Run one cut at a time.

### Error codes

With `--json`, a failed command prints `{"error": "<text>", "code": "<code>"}` and exits 1. Match the code, never the text. `cut-release` codes:

| Code | Refused because |
|---|---|
| `tag_exists` | the tag of that version exists |
| `not_newer` | the version is not newer than the newest tag |
| `release_open` | another release branch is open |
| `already_shipped` | the branch already went into main |
| `no_remote` | there is no git remote |
| `invalid_args` | `--next` was given with a version, or with anything but `minor` or `patch` |
| `invalid_version` | the version is not x.y.z, or neither a version nor `--next` was given |

Every other failure (a file system error, a failed git command) prints `"code": "error"`. Text output is unchanged.

## `release ship`

1. On the release branch: `git-flow changelog --write`, review `CHANGELOG.md`, commit it (`chore(release): changelog for x.y.z`), push.
2. `git-flow check-pr --base <main> --head release/x.y.z`. If it says the branch is behind, run `back-merge` first.
3. `gh pr create --base <main> --head release/x.y.z --title "Release x.y.z" --body "<the changelog section>"`.
4. Wait for `gh pr checks <n>` to pass. Then `gh pr merge <n> --merge` (release-train) or `--squash` (trunk). Never `--auto` on a repo without branch protection.
5. CI tags `vx.y.z`. Confirm: `git fetch --tags && git tag --list 'v<x.y.z>'`.
6. Retarget any PR based on the release branch, then delete it.

## `release status`

`git-flow status`.

`git-flow active-release` prints the open `release/x.y.z` and refuses when two are open. `git-flow active-release --json` exits 0 either way and returns `{activeRelease, open, malformed}`: `open` lists every open release oldest first, `activeRelease` is the one open release or `null` (none, or more than one), and `malformed` lists `release/*` branches that are not `release/x.y.z`.

## `hotfix <issue>`

```bash
git fetch origin
git checkout -b hotfix/<issue> origin/<main>
# fix, then set the version the tagger will produce:
git-flow bump-version --branch
git add -- <fixed files> <version files>
git commit -m "fix(scope): ..."
git push -u origin hotfix/<issue>
gh pr create --base <main> --title "fix(scope): ..." --body "..."
gh pr checks <n>             # must be green
gh pr merge <n> --squash
```

If another release or hotfix lands first, run `bump-version --branch` again and push before merging. Then back-merge.

## `back-merge`

```bash
git checkout release/x.y.z && git pull --ff-only
git-flow back-merge          # merges <remote>/<main>; version files keep the release's version, CHANGELOG.md keeps both sides
git push
```

Version files merge like any other file, so a hotfix's other changes to them (a new dependency, say) are kept; only the version field stays the release's. It stops on any other conflict, including a real conflict inside a version file, and lists the files: resolve them, stage them by name, commit.

## Versions and tags

| Case | Command |
|---|---|
| Release | `cut-release` commits the bump |
| Hotfix | `bump-version --branch`, committed with the fix |
| Explicit | `bump-version <x.y.z>` |
| Check only | `bump-version --check <x.y.z>` |
| What a branch releases | `resolve-version --head <branch>` |

- The files are `git.versionFiles` (JSON with a dot path, or a regex whose first group is the version).
- Never create release tags by hand. CI runs `git-flow tag-release --sha <merge>` on each push to main; it re-checks the merge and refuses to tag one that broke the flow.
