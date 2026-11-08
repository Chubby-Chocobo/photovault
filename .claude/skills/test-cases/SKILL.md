---
name: test-cases
description: "Generate test cases from use cases, update when requirements change, export to CSV/JSON."
when_to_use: "Invoke when test cases must be generated from use cases, refreshed after requirement changes, or exported for QA."
user-invocable: true
argument-hint: "generate [module[/uc]]|update|export csv|json"
category: utilities
keywords: [qa, test-cases, coverage, csv, export]
metadata:
  author: adf
  version: "1.0.0"
---

# Test Case Management

Generate, update, and export test cases from use case documentation.

## Default (No Arguments)

If invoked without arguments, use `AskUserQuestion` to present available operations:

| Operation | Description |
|-----------|-------------|
| `generate` | Generate test cases from use cases |
| `update` | Sync test cases with use case changes |
| `export` | Export test cases to CSV or JSON |

Present as options via `AskUserQuestion` with header "Test Case Management", question "What would you like to do?".

## Subcommands

| Subcommand | Reference | Purpose |
|------------|-----------|---------|
| `/test-cases generate` | `references/generate-workflow.md` | Generate TCs for all use cases |
| `/test-cases generate {module}` | `references/generate-workflow.md` | Generate TCs for specific module |
| `/test-cases generate {module}/{uc}` | `references/generate-workflow.md` | Generate TCs for specific use case |
| `/test-cases update` | `references/update-workflow.md` | Sync TCs with use case changes |
| `/test-cases export csv` | `references/export-workflow.md` | Export all TCs to CSV |
| `/test-cases export json` | `references/export-workflow.md` | Export all TCs to JSON |

## Routing

Parse `$ARGUMENTS`:
- Starts with `generate` → Load `references/generate-workflow.md`, pass remaining args as scope
- `update` → Load `references/update-workflow.md`
- Starts with `export` → Load `references/export-workflow.md`, pass format (csv/json) as arg
- empty/unclear → AskUserQuestion

## Shared Context

- TC template: `references/templates/test-case-template.md`
- Summary template: `references/templates/test-summary-template.md`
- Input UCs: `docs/requirements/usecases/{module}/*.md`
- Input SRS: `docs/requirements/srs.md`
- Output TCs: `docs/testing/testcases/{module}/tc-{module}-{nnn}-{slug}.md`
- Output summary: `docs/testing/test-summary.md`
- Output config: `docs/testing/test-config.md` (created once on first generate, manually maintained after)
- Config template: `references/templates/test-config-template.md`
- Output exports: `docs/testing/exports/`

**Do not** start implementing code. This skill produces test case documentation only.
