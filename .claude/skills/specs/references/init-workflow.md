# Init Workflow — /specs init

Generate initial SRS and use case documents from existing codebase.

## Steps

### 1. Detect Project Type

Run the detection script and capture result:
```bash
sh .claude/skills/common/detect-project-type.sh
```

Store the result (e.g., `web-frontend`, `api-backend`, `fullstack-web`, `mobile`, `unknown`).

### 2. Read Business Context

Read `docs/requirements/prd.md` for:
- Project goals and scope
- Target users and personas
- Key features and requirements
- Business constraints

If file doesn't exist, warn user: "No PRD found. Run `/docs init` first for better results."

### 3. Scout Codebase for Modules

Identify logical modules by analyzing:
- Directory structure (src/, app/, routes/, features/, modules/)
- Route definitions (API endpoints, page routes)
- Domain entities (models, schemas, types)
- Feature groupings

Goal: produce a list of modules (e.g., auth, payment, users, products).

### 4. Spawn Business Analyst Agent

Spawn `business-analyst` agent via Agent tool with:

```
Create initial SRS and use case documents.

Project type: {detected-type}
PRD context: {prd-content-summary}
Identified modules: {module-list}

Instructions:
1. Read templates:
   - SRS: .claude/skills/specs/references/templates/srs-template.md
   - UC: .claude/skills/specs/references/templates/use-case-template.md

2. Create docs/requirements/srs.md:
   - Fill all applicable sections based on project type
   - Omit sections not applicable (see section filtering in agent definition)
   - Cross-reference use cases in each module's feature specs

3. Create docs/requirements/usecases/{module}/ directories for each module

4. Create use case files: uc-{module}-{nnn}-{slug}.md
   - Follow template structure
   - Assign meaningful IDs: UC-{MODULE}-{NNN}
   - Set priority based on business criticality

5. Ensure cross-references:
   - SRS feature specs link to use case files
   - Use cases reference applicable business rules (BR-NNN)

Work context: {project-root}
```

### 5. Output Summary

After agent completes, report:
- Project type detected
- Modules identified
- Number of use cases created per module
- SRS sections included/excluded based on project type

## Important
- Use `docs/` directory as output location for SRS and usecases
- **Do not** implement any code — documentation only
