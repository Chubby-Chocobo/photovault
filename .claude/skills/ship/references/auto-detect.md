# Auto-Detection Logic

Detect the test runner and review scope from project files. Targets and versions come from the git workflow.

## Test Runner Detection

Check in order (first match wins):

| Check | Test Command |
|-------|-------------|
| `package.json` → `scripts.test` exists | `npm test` |
| `Makefile` → has `test:` target | `make test` |
| `pytest.ini` OR `pyproject.toml` has `[tool.pytest]` | `pytest` |
| `Cargo.toml` exists | `cargo test` |
| `go.mod` exists | `go test ./...` |
| `Gemfile` + `Rakefile` with test task | `bundle exec rake test` |
| `build.gradle` or `build.gradle.kts` | `./gradlew test` |
| `pom.xml` | `mvn test` |
| `mix.exs` | `mix test` |
| `deno.json` | `deno test` |

**Detection script:**
```bash
if [ -f package.json ] && grep -q '"test"' package.json 2>/dev/null; then
  echo "npm test"
elif [ -f Makefile ] && grep -q '^test:' Makefile 2>/dev/null; then
  echo "make test"
elif [ -f pytest.ini ] || ([ -f pyproject.toml ] && grep -q '\[tool.pytest' pyproject.toml 2>/dev/null); then
  echo "pytest"
elif [ -f Cargo.toml ]; then
  echo "cargo test"
elif [ -f go.mod ]; then
  echo "go test ./..."
else
  echo "NONE"
fi
```

**If NONE:** Use `AskUserQuestion` — "No test runner detected. Options: A) Skip tests, B) Provide test command"

## Version Files

`/ship` does not choose versions. The version files are `git.versionFiles` in `.claude/config/adf-config.json`, written by `git-flow.cjs cut-release` and `bump-version`. When a project has no `package.json` and no `versionFiles`, `git-flow.cjs` names the manifest it found (`pyproject.toml`, `Cargo.toml`, `build.gradle`, `pom.xml`, `pubspec.yaml`, `*.csproj`) and the config to paste.

## Main Branch Detection

```bash
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'
```

Fallback: check if `main` or `master` exists:
```bash
git rev-parse --verify origin/main 2>/dev/null && echo "main" || echo "master"
```
