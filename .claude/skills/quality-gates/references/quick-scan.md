# Quick Scan (dependency-free)

Use when gitleaks/trivy/semgrep are not installed, or for a fast ad-hoc check. Uses Grep + `npm audit`/`pip audit` + reasoning. For gated, CI-ready runs use `/quality-gates run`.

Invoke with `/quality-gates run --mode quick` intent: follow the steps below directly (no scripts).

## Steps

1. **Detect project type**: `package.json` (Node), `requirements.txt`/`pyproject.toml` (Python), `go.mod` (Go), `Cargo.toml` (Rust).
2. **Secrets (always first)**: Grep with patterns from `quick-scan-secret-patterns.md` (API keys, private keys, DB URLs with credentials, hardcoded passwords). Exclude `.env.example`, fixtures, docs, vendored and build output. Verify each match is real (not `YOUR_API_KEY`). Severity: CRITICAL (exposed prod key), HIGH (real credential), MEDIUM (possible).
3. **Dependencies**: `npm audit --json` / `pip audit --format json` (tolerate failure). Group by critical/high/moderate/low.
4. **Code patterns**: Grep with `quick-scan-vulnerability-patterns.md` (SQLi, XSS, command injection, path traversal, insecure randomness, `eval`). Read 5-10 lines of context; drop false positives; rate severity and suggest a fix.
5. **.env exposure**: `git ls-files --error-unmatch .env .env.local .env.production` and `grep -n "\.env" .gitignore`.
6. **Report** in chat: summary table (Secrets/Deps/Code x severity) plus findings by severity with `file:line`, pattern, fix. In `--auto` cook flow save to `plans/reports/quality-gates-quick-scan-{date}.md`.

## Policy

- Never print full secrets: redact to first 4 + last 2 chars.
- Never execute found credentials; never auto-modify code, only report with fix suggestions.
- Real credential found: recommend immediate rotation.
- Out of scope: pentesting, runtime analysis, infra security, compliance audits (use `/security` for STRIDE audit).
