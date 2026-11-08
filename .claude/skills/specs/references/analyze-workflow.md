# Analyze Workflow — /specs analyze "feature description"

Analyze a new feature requirement and update SRS + use cases.

## Arguments

Everything after `analyze` in `$ARGUMENTS` is the feature description.
Example: `/specs analyze "add two-factor authentication to login flow"`

## Steps

### 1. Detect Project Type

```bash
sh .claude/skills/common/detect-project-type.sh
```

### 2. Read Current State

Read existing documents:
- `docs/requirements/srs.md` — current SRS
- `docs/requirements/usecases/` — list existing modules and use cases via Glob

If SRS doesn't exist, warn: "No SRS found. Run `/specs init` first, or I'll create it now."

### 3. Spawn Business Analyst Agent

Spawn `business-analyst` agent via Agent tool with:

```
Analyze new feature and update requirements documentation.

Feature description: {feature-description}
Project type: {detected-type}
Current SRS: {srs-summary-or-note-if-missing}
Existing modules: {list-of-modules-from-usecases-dir}

Instructions:
1. Determine which module this feature belongs to (existing or new)
2. Read templates:
   - SRS: .claude/skills/specs/references/templates/srs-template.md
   - UC: .claude/skills/specs/references/templates/use-case-template.md

3. Update docs/requirements/srs.md:
   - Add/update feature spec section for the relevant module
   - Add new business rules if applicable
   - Update data models if new entities needed
   - Add API contracts if new endpoints (api-backend/fullstack-web)
   - Add screen descriptions if new screens (web-frontend/fullstack-web/mobile)

4. Create new use case files in docs/requirements/usecases/{module}/:
   - Determine next available UC number for the module
   - Follow template structure
   - Cross-reference with SRS

5. If creating a new module:
   - Create docs/requirements/usecases/{module}/ directory
   - Add module section to SRS

Work context: {project-root}
```

### 4. Output Summary

Report:
- Module affected (new or existing)
- Use cases created/updated
- SRS sections modified
- New business rules added

## Important
- Do not remove existing use cases — only add or update
- Preserve existing SRS content when adding new sections
