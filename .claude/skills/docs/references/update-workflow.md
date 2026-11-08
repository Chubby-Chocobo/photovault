# Update Workflow

## Phase 1: Parallel Codebase Scouting

1. Scan the codebase and calculate the number of files with LOC in each directory (skip `.claude`, `.git`, `tests`, `node_modules`, `__pycache__`, `secrets`, etc.)
2. Target directories **that actually exist** - adapt to project structure
3. Activate `scout` skill to explore the code base and return detailed summary reports
4. Merge scout reports into context summary

## Phase 1.5: Parallel Documentation Reading

**You (main agent) spawn the readers** so the reports reach `docs-manager` as one merged context.

1. Count docs: `find "${ADF_DOCS_PATH:-docs}" -name '*.md' -type f | wc -l`
2. Get LOC: `find "${ADF_DOCS_PATH:-docs}" -name '*.md' -type f -exec wc -l {} + | sort -rn` (recursive; never scan `plans/`)
3. Strategy:
   - 1-3 files: Skip parallel reading, docs-manager reads directly
   - 4-6 files: Spawn 2-3 `Explore` agents
   - 7+ files: Spawn 4-5 `Explore` agents (max 5)
4. Distribute files by LOC (larger files get dedicated agent)
5. Each agent prompt: "Read these docs, extract: purpose, key sections, areas needing update. Files: {list}"
6. Merge results into context for docs-manager

## Phase 2: Documentation Update (docs-manager Agent)

You must spawn `docs-manager` agent via Agent tool with merged reports and doc readings.

Pass the gathered context to docs-manager agent to update documentation:
- `README.md`: Update README (keep it under 300 lines)
(`docs/` below is the configured `paths.docs`.)

- `docs/requirements/prd.md`: Update project overview, business goals and PRD
- `docs/architecture/codebase-summary.md`: Update codebase summary
- `docs/conventions/code-standards.md`: Update codebase structure and code standards
- `docs/architecture/system-architecture.md`: Update system architecture
- `docs/requirements/roadmap.md`: Update project roadmap
- `docs/conventions/deployment.md` [optional]: Update deployment guide
- `docs/README.md`: keep the map in sync with the folders and files that exist
- `docs/design/design-system/design-principles.md` [optional]: Update design principles
- `docs/requirements/srs.md` [if exists]: Check SRS staleness — if new modules/features in code lack SRS coverage, flag and suggest running `/specs update`
- `docs/requirements/usecases/` [if exists]: Check for orphaned use cases or missing coverage

## Additional requests
<additional_requests>
  $ARGUMENTS
</additional_requests>

## Phase 3: Size Check (Post-Update)

After docs-manager completes:
1. Run `find "${ADF_DOCS_PATH:-docs}" -name '*.md' -type f -exec wc -l {} + | sort -rn` (recursive; never scan `plans/`) to check LOC
2. Use `docs.maxLoc` from session context (default: 800)
3. For files exceeding limit: report and ask user

## Phase 4: Documentation Validation (Post-Update)

Run validation to detect potential hallucinations:
1. Run: `node .claude/scripts/validate-docs.cjs "${ADF_DOCS_PATH:-docs}"`
2. Display validation report (warnings only, non-blocking)
3. Checks: code references, internal links, config keys

## Important
- Use the docs directory (`paths.docs`) as the source of truth.
- **Do not** start implementing.
