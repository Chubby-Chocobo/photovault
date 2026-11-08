# Commit Message Standards

## Format
```
type(scope): description
```

## Types (priority order)
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Formatting (no logic change)
- `refactor`: Restructure without behavior change
- `test`: Tests
- `chore`: Maintenance, deps, config
- `perf`: Performance
- `build`: Build system
- `ci`: CI/CD

Types come from the project's commitlint `type-enum` (JSON configs) when it has one, else the list above plus `revert`.

## Rules
- **Under 72 characters**
- **Present tense, imperative** ("add" not "added")
- **No period at end**
- **Scope optional but recommended**
- **Focus on WHAT, not HOW**
- `git.commit.pathTypes` can limit the types allowed under a folder (for example `{".claude/": ["feat", "fix", "perf"]}`); follow it when set.
- No unstable identifiers: keep plan IDs, phase numbers, audit labels and session references out of messages; describe the behavior or reason.

## Never Include AI Attribution
- ❌ "Generated with Claude"
- ❌ "Co-Authored-By: Claude"
- ❌ Any AI reference

## Good Examples
- `feat(auth): add login validation`
- `fix(api): resolve query timeout`
- `docs(readme): update install guide`
- `refactor(utils): simplify date logic`

## Bad Examples
- ❌ `Updated files` (not descriptive)
- ❌ `feat(auth): added login using bcrypt with salt` (too long, describes HOW)
- ❌ `Fix bug` (not specific)

## Enforcement
The `commit-guard` hook checks format, length, trailing period, AI attribution and `pathTypes` at `git.enforcement` (`off`, `ask`, `deny`).
