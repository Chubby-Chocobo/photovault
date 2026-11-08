# Init Workflow

## Phase 1: Parallel Codebase Scouting

1. Scan the codebase and calculate the number of files with LOC in each directory (skip credentials, cache or external modules directories, such as `.claude`, `.git`, `tests`, `node_modules`, `__pycache__`, `secrets`, etc.)
2. Target directories **that actually exist** - adapt to project structure, don't hardcode paths
3. Activate `scout` skill to explore the code base and return detailed summary reports to the main agent
4. Merge scout reports into context summary

## Phase 2: Documentation Creation (docs-manager Agent)

You must spawn `docs-manager` agent via Agent tool with merged reports. Do not wait for user input.

Pass the gathered context to docs-manager agent to create initial documentation:
- `README.md`: Update README with initial documentation (keep it under 300 lines)
(`docs/` below is the configured `paths.docs`.)

- `docs/requirements/prd.md`: Project overview, business goals and PRD (Product Requirements Document)
- `docs/architecture/codebase-summary.md`: Codebase summary
- `docs/conventions/code-standards.md`: Codebase structure and code standards (start with front matter `description: <one line>`; it feeds the conventions index at session start)
- `docs/architecture/system-architecture.md`: System architecture. In a workspace or monorepo it stays system-wide: the component list and how components interact, taken from the system map
- `docs/architecture/services/<name>.md`: one per component, only in a workspace or a monorepo with a system map (see below)
- `docs/requirements/roadmap.md`: Project roadmap
- `docs/conventions/deployment.md` [optional]: Deployment guide (front matter `description:` too)
- `docs/design/design-system/design-principles.md` [optional]: Design principles
- `docs/README.md`: fill the map seeded by the installer (from `.claude/templates/docs/README.md`) with what now exists; keep it as the map, not a copy of the docs

### Workspace or monorepo with a system map

When `docs/architecture/system-map.json` exists (workspace, or monorepo after `seed-map`), scaffold the per-component files first. This step asks the user; the rest of Phase 2 does not.

1. Run `node .claude/skills/workspace/scripts/workspace.cjs scaffold --dry-run` and show the user which component `AGENTS.md` and `CLAUDE.md` files and service docs it would write. It lists only files that are missing and never touches an existing one.
2. After the user confirms, run it again with `--yes`.
3. Pass the scout reports and the written `docs/architecture/services/<name>.md` files to docs-manager, which fills Purpose, Data stores, Run and deploy and Owners from the code.

Never create a `docs/` folder inside a component or member. A component's own `CLAUDE.md` stays short and points to the root docs.

## Phase 3: Size Check (Post-Generation)

After docs-manager completes:
1. Run `find "${ADF_DOCS_PATH:-docs}" -name '*.md' -type f -exec wc -l {} + | sort -rn` to check LOC (recursive; never scan `plans/`)
2. Use `docs.maxLoc` from session context (default: 800)
3. For files exceeding limit:
   - Report which files exceed and by how much
   - docs-manager should have already split proactively
   - If still oversized, ask user: split now or accept as-is?
