---
name: specs
description: "Analyze requirements, create/maintain SRS and use cases. Use for business analysis, requirements documentation, SRS, BRD."
when_to_use: "Invoke when the SRS, use cases or a BRD must be created or synced with new requirements or code changes."
user-invocable: true
argument-hint: "init|analyze 'description'|update|brd"
category: utilities
keywords: [requirements, srs, brd, use-cases, business-analysis, specs]
metadata:
  author: adf
  version: "1.0.0"
---

# Business Analysis

Create and maintain the Software Requirements Specification (SRS), optional Business Requirements Document (BRD) and use case documentation through codebase analysis and requirements engineering.

## Default (No Arguments)

If invoked without arguments, use `AskUserQuestion` to present available operations:

| Operation | Description |
|-----------|-------------|
| `init` | Analyze codebase & create SRS + use cases |
| `analyze` | Analyze new feature requirements |
| `update` | Sync SRS & use cases with codebase |
| `brd` | Capture client business requirements in a BRD |

Present as options via `AskUserQuestion` with header "Business Analysis", question "What would you like to do?".

## Subcommands

| Subcommand | Reference | Purpose |
|------------|-----------|---------|
| `/specs init` | `references/init-workflow.md` | Analyze codebase and create initial SRS + use cases |
| `/specs analyze "feature"` | `references/analyze-workflow.md` | Analyze new feature and update SRS + use cases |
| `/specs update` | `references/update-workflow.md` | Sync SRS + use cases with current codebase state |
| `/specs brd` | (below) | Create or update `docs/requirements/brd.md` for projects whose client supplies business requirements |

## Routing

Parse `$ARGUMENTS` first word:
- `init` → Load `references/init-workflow.md`
- `analyze` → Load `references/analyze-workflow.md`, pass remaining args as feature description
- `update` → Load `references/update-workflow.md`
- `brd` → Run the BRD steps below
- empty/unclear → AskUserQuestion

## BRD (optional)

Only for projects where a client or sponsor supplies business requirements. Skip it otherwise; the PRD already carries business goals.

1. Read `docs/requirements/prd.md` and any client material the user points to.
2. Create or update `docs/requirements/brd.md` from `references/templates/brd-template.md`; drop sections with no content.
3. Keep SRS requirements traceable: reference BRD IDs (BG-/BRQ-) from the SRS where they apply.

## Shared Context

- Detection script: `.claude/skills/common/detect-project-type.sh`
- SRS template: `references/templates/srs-template.md`
- UC template: `references/templates/use-case-template.md`
- BRD template: `references/templates/brd-template.md`
- PRD input: `docs/requirements/prd.md` (business goals live there)
- Optional BRD: `docs/requirements/brd.md`
- Output SRS: `docs/requirements/srs.md`
- Output UCs: `docs/requirements/usecases/{module}/uc-{module}-{nnn}-{slug}.md`

**Note**: This skill was previously named `/ba`. All references now use `/specs`.

**Do not** start implementing code. This skill produces documentation only.
