# Ship Workflow — Detailed Steps

## Step 1: Pre-flight

1. Read `docs/conventions/git-workflow.md` and run `node .claude/skills/git/scripts/git-flow.cjs status`.
2. Check current branch: `git branch --show-current`.
   - On the main branch: **ABORT**: "Ship from a feature, fix or hotfix branch."
   - On a `release/*` branch: this is a release ship. Hand over to `/git release ship` and stop.
3. Target branch:
   - When `git.flow` is `release-train` or `trunk`: `TARGET=$(node .claude/skills/git/scripts/git-flow.cjs pr-target)`. If it fails because no release is open, **stop** and suggest `/git release cut <x.y.z>`.
   - When `git.flow` is `off`: `official` targets the default branch (`git symbolic-ref refs/remotes/origin/HEAD`), `beta` the first of `dev`, `beta`, `develop` on the remote; with no argument, ask.
4. Run `git status` (never use `-uall`).
5. Run `git diff origin/<target>...HEAD --stat` and `git log origin/<target>..HEAD --oneline` to understand what's being shipped.
6. If `--dry-run`: output what would happen at each step and stop here.

## Step 2: Link Issues

Find related GitHub issues for traceability.

1. Search for related open issues by keywords from branch name and commit messages:
   ```bash
   # Extract keywords from branch name
   BRANCH=$(git branch --show-current)
   KEYWORDS=$(echo "$BRANCH" | sed 's/[^a-zA-Z0-9]/ /g' | tr '[:upper:]' '[:lower:]')

   # Search existing issues
   gh issue list --state open --limit 10 --search "$KEYWORDS"
   ```

2. Also check if any issues are referenced in commit messages:
   ```bash
   git log <target>..HEAD --oneline | grep -oE '#[0-9]+' | sort -u
   ```

3. **If related issues found:** Note issue numbers for PR linking.

4. **If NO related issues found:** Continue without a linked issue. `/ship` never creates an issue on its own (it is an external side effect, and `/vibe` already creates one). If the user wants one, they run `gh issue create`.

5. Store issue numbers for Step 12 (PR creation).

## Step 3: Merge target branch

Fetch and merge the target (from Step 1) so tests run against the merged state:

```bash
git fetch origin <target> && git merge origin/<target> --no-edit
```

Never merge the main branch into a feature branch of a release train; the target there is the release branch.

- **If merge conflicts:** Try auto-resolve simple ones (lockfiles, version files). For complex conflicts, **Stop** and show them.
- **If already up to date:** Continue silently.

## Step 4: Run Tests

**Skip if:** `--skip-tests` flag.

1. Auto-detect test command (see `auto-detect.md`)
2. Delegate to `tester` subagent — don't inline test execution
3. Check pass/fail from agent result

- **If any test fails:** Show failures and **Stop**. Do not proceed.
- **If all pass:** Note counts briefly and continue.
- **If no test runner detected:** Use `AskUserQuestion` — "No test runner detected. Skip tests or provide command?"

## Step 5: Pre-Landing Review

**Skip if:** `--skip-review` flag.

1. Run `git diff origin/<target>` to get the full diff, and read each new untracked file from `git ls-files -o --exclude-standard` that belongs to this change (the diff does not show them)
2. Delegate to `code-reviewer` subagent with the diff
3. Two-pass model:
   - **Pass 1 (CRITICAL):** Security, injection, race conditions, auth bypass
   - **Pass 2 (INFORMATIONAL):** Dead code, magic numbers, test gaps, style

4. **Output findings:**
   ```
   Pre-Landing Review: N issues (X critical, Y informational)
   ```

5. **If critical issues found:** For EACH critical issue, use `AskUserQuestion`:
   - Problem description with `file:line`
   - Recommended fix
   - Options: A) Fix now (recommended), B) Acknowledge and ship, C) False positive — skip

6. **If user chose Fix (A):** Apply fixes, commit fixed files, then **re-run tests** (Step 4) before continuing.
7. **If only informational:** Include in PR body, continue.
8. **If no issues:** Output "No issues found." and continue.

## Step 6: Version (hotfix only)

Versions are set by the git workflow, not by `/ship`:
- **Hotfix branch:** run `node .claude/skills/git/scripts/git-flow.cjs bump-version --branch` and include the version files in the commit. The PR into main fails its check without it.
- **Feature or fix branch:** nothing to do. The release's version was set by `cut-release`.
- **`git.flow: off`:** nothing to do unless the user asks; then `bump-version <x.y.z>`.

## Step 7: Changelog

Skip. The release changelog is written from the commit subjects when the release ships (`git-flow.cjs changelog --write`), so a feature branch never edits `CHANGELOG.md`. Good commit subjects are what make the changelog.

## Step 8: Journal (opt-in, background)

**Skip unless:** `--journal` flag.

Record a setback or hard decision from this ship session with cause and lesson. Run as **background task** to not block pipeline.

1. Invoke `/journal` skill via `journal-writer` subagent in background:
   - Topic: summary of shipped changes (from commit messages + diff stats)
   - Include: the setback or hard decision, its cause, the lesson
   - Output: saved to `./plans/journals/` directory
2. If `--wiki` is passed and a local journal file is produced before PR creation, publish it to AgentWiki:
   - Build publish content as markdown: `## Summary` with 2-4 concise bullets, then the full journal body. Redact secrets, tokens, customer data, private URLs, and raw logs before upload.
   - Detect CLI first:
     ```bash
     command -v agentwiki >/dev/null 2>&1
     ```
   - If CLI exists, identify the project doc folder from the current repo:
     ```bash
     gh repo view --json nameWithOwner --jq .nameWithOwner
     agentwiki doc-folders list --json --full-ids
     ```
   - Prefer an existing folder whose path or name exactly matches `<repo-owner>/<repo-name>` or `<repo-name>`. If none exists, create the missing project folder under the closest existing owner/project parent; if no suitable parent exists, create `<repo-name>` at the root.
   - Publish the prepared markdown with title, category, tags, and folder:
     ```bash
     agentwiki doc upload <prepared-journal-file> \
       --title "<YYYY-MM-DD> <ship summary>" \
       --category "technical-diary" \
       --tags "technical-diary,journal,ship,<repo-name>,<branch-name>,<ship-mode>" \
       --folder <folder-id> \
       --json
     ```
   - If CLI is missing but AgentWiki MCP document tools exist, use MCP to create the same project folder when needed, then create a document with:
     - Title: `<YYYY-MM-DD> <ship summary>`
     - Category: `technical-diary`
     - Tags: `technical-diary`, `journal`, `ship`, repo name, branch name, ship mode
     - Content: the prepared markdown with summary first, then full journal body
     - Folder: the matching project folder ID when discoverable or newly created
   - If neither CLI nor MCP exists, skip AgentWiki publish silently. Do not fail ship.
   - If AgentWiki exists but returns auth, permission, quota, or network errors, record the error in ship output and continue unless the user explicitly requested AgentWiki publish as mandatory.
3. Don't wait for background journal completion — continue to next step immediately. If the note completes after PR creation, publish then and update final output with the document URL or ID when available.

## Step 9: Docs Update (conditional)

**Skip if:** `--skip-docs` flag OR ship mode is `beta`.

Update project documentation only when the change affects user-visible behavior, setup, commands or architecture; otherwise skip.

1. Invoke `/docs update` skill via `docs-manager` subagent:
   - Analyzes the code changes on this branch
   - Updates relevant docs in the docs path (`paths.docs`, shown in session context)
   - Never edits `CHANGELOG.md`
2. **Wait for it to finish** before Step 10, so its edits are staged and committed with the change and never half-written.

## Step 10: Commit

1. Stage the files this change owns, by name: `git status --short`, then `git add -- <path> ...`. Never `git add -A`, `git add .` or `git commit -a`; leave unrelated changes and working output (plans, reports) alone.
2. Security check: the `commit-guard` hook asks when staged changes hold secret files or credentials. If it asks: **Stop**, unstage the file, suggest moving the value to an untracked `.env`.
3. Compose commit message:
   - Format: `type(scope): description`
   - Infer type from changes (feat/fix/refactor/chore)
   - On a hotfix, include the version files in the same commit
4. Commit:

```bash
git commit -m "$(cat <<'EOF'
type(scope): description

Brief body describing the changes.
EOF
)"
```

## Step 11: Push

```bash
git push -u origin $(git branch --show-current)
```

- **Never force push.**
- If push rejected: suggest `git pull --rebase` and retry once.

## Step 12: Create PR

Check if `gh` CLI is available:
```bash
which gh 2>/dev/null || echo "MISSING"
```

If missing: output "Install GitHub CLI (gh) to auto-create PRs" and stop after push.

Create PR targeting the correct branch:
```bash
node .claude/skills/git/scripts/git-flow.cjs check-pr --base <target-branch> --head "$(git branch --show-current)"   # stop if it fails
gh pr create --base <target-branch> --title "<type>: <summary>" --body "$(cat <<'EOF'
<PR body from pr-template.md>
EOF
)"
```

**Link issues** collected from Step 2:
```bash
# If issues were found, add closing keywords in PR body
# e.g., "Closes #42, Relates to #43"
```

**Output the PR URL** — this is the final output the user sees.

If PR already exists for this branch, update it instead:
```bash
gh pr edit --title "<type>: <summary>" --body "$(cat <<'EOF'
<PR body>
EOF
)"
```
