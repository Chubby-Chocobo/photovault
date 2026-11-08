# Per-Project Settings and CI

## Where things live

| Layer | Owner | Holds |
|---|---|---|
| `git` skill, `git-flow.cjs`, hooks, CI template | ADF (updated on install) | the generic standard; reads every value from config |
| `git` in `.claude/config/adf-config.json` | the project | the machine-checked values |
| `docs/conventions/git-workflow.md` | the project, except its settings block (between the `adf:git-settings` markers) | the process as the team runs it, plus project-only duties; the block states the `git` values as text and the installer rewrites it unless the project edited it |
| `.github/workflows/adf-git-guards.yml` after `setup-ci` | the project | guard and tag jobs, plus the project's own jobs |

## The `git` section

```json
{
  "git": {
    "flow": "release-train",
    "enforcement": "ask",
    "mainBranch": "main",
    "versionFiles": [{ "path": "package.json", "json": "version" }],
    "directPush": { "paths": ["docs/**", ".github/**", "README.md", "CHANGELOG.md"] }
  }
}
```

- `flow`: `release-train`, `trunk` or `off`.
- `enforcement`: what hooks do on a violation: `off`, `ask` or `deny`. Force-pushing a protected branch is always denied; secrets always ask.
- `versionFiles`: JSON files take `"json": "dot.path"`; others take `"regex"` with the version as group 1, for example `{ "path": "pyproject.toml", "regex": "^version = \"([^\"]+)\"" }`.
- Optional: `tagPrefix` (default `v`), `commit.pathTypes` (folder prefix → allowed commit types).
- Commit types come from the project's JSON commitlint `type-enum`, else the conventional list.

## `setup-ci`

```bash
node .claude/skills/git/scripts/git-flow.cjs setup-ci          # writes the workflow once, never overwrites
node .claude/skills/git/scripts/git-flow.cjs setup-ci --check  # reports drift from ADF's template
```

The workflow runs `check-pr` on PRs into main, `check-push` and `tag-release` on pushes to main. Add deploy jobs after `tag-release` in the same file, because tags pushed with `GITHUB_TOKEN` do not start other workflows.
