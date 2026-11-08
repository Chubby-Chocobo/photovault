# Wiki Publish (`--wiki`, optional)

Use only when `--wiki` was passed to `brainstorm-technical` or `brainstorm-features`. Publishing is optional and never blocks the brainstorm. Skip it silently-but-reported when the `agentwiki` tool is unavailable.

Run after the local markdown report (and the HTML report when `--html` is present) exists.

1. Redact secrets, tokens, customer data, private URLs, and raw logs from the outputs before upload.
2. Detect the CLI: `command -v agentwiki >/dev/null 2>&1`.
3. Markdown report: `agentwiki doc upload <report.md> --title "<title>" --description "<summary>" --category "brainstorm-report" --tags "brainstorm,<repo-name>" --json`, then `agentwiki doc publish <id> --description "<summary>" --json` using the returned document ID.
4. HTML report (only with `--html`): `agentwiki sites upload <report.html> --description "<summary>" --auto-summary`.
5. Prefer an existing project folder from `agentwiki doc-folders list --json`. If folder detection fails, publish without a folder.
6. If the CLI is missing but AgentWiki MCP document/site tools are available, create equivalent document and site records through MCP.
7. If neither exists, record `Wiki publish skipped: agentwiki unavailable` in the final response. Do not fail the brainstorm unless the user explicitly made publishing mandatory.

Report the resulting document/site URLs, or the exact skip reason, in the final response.
