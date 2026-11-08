# Unified Workflow Steps

All modes share core steps with mode-specific variations.

Scale every step to the task size chosen in Step 0 (see `SKILL.md` "Size the Task First"). Small tasks skip plan files and subagents; the steps below describe medium and large tasks.

## Step 0: Intent Detection & Setup

1. Parse input with `intent-detection.md` rules
2. Log detected mode and task size: `✓ Step 0: Mode [X], size [small|medium|large] - [reason]`
3. If mode=code: detect plan path, set active plan
4. Use `TaskCreate` to create workflow step tasks (with dependencies if complex)

**Output:** `✓ Step 0: Mode [interactive|auto|fast|parallel|no-test|code] - [detection reason]`

## Step 1: Research (skip if fast/code mode)

**Interactive/Auto:**
- Spawn multiple `researcher` agents in parallel
- Use `/scout ext` or the `Explore` subagent for codebase search
- Keep reports ≤150 lines

**Parallel:**
- Optional: max 2 researchers if complex

**Output:** `✓ Step 1: Research complete - [N] reports gathered`

### [Review Gate 1] Post-Research (skip if auto mode)
- Present research summary to user
- Use `AskUserQuestion` to ask: "Proceed to planning?" / "Request more research" / "Abort"
- **Auto mode:** Skip this gate

## Step 2: Planning

**Interactive/Auto/No-test:**
- Use `planner` agent with research context
- Create `plan.md` + `phase-XX-*.md` files

**Fast:**
- Use `/adf-plan --fast` with scout results only
- Minimal planning, focus on action

**Parallel:**
- Use `/adf-plan --parallel` for dependency graph + file ownership matrix (ownership may come from each phase's `touches`)

**Code:**
- Skip - plan already exists
- Parse existing plan for phases

**Output:** `✓ Step 2: Plan created - [N] phases`

### [Review Gate 2] Post-Plan (skip if auto mode)
- Present plan overview with phases
- Use `AskUserQuestion` to ask: "Validate the plan or approve plan to start implementation?" - "Validate" / "Approve" / "Abort" / "Other" ("Request revisions")
  - "Validate": run `/adf-plan validate` skill invocation
  - "Approve": continue to implementation
  - "Abort": stop the workflow
  - "Other": revise the plan based on user's feedback
- **Auto mode:** Skip this gate

## Step 3: Implementation

1. `TaskList` first — check for existing tasks (hydrated by planning skill in same session)
2. If tasks exist → pick them up, skip re-creation
3. If no tasks → read plan phases, `TaskCreate` for each unchecked `[ ]` item with priority order and metadata (`phase`, `planDir`, `phaseFile`)
4. Tasks can be blocked by other tasks via `addBlockedBy`

### Conformance Checklist (before writing code)

Before implementing each phase, the developer agent should:

1. **Read `./docs/conventions/code-standards.md`** and confirm naming, file structure, and
   error-handling patterns still match the repo.
2. **Scout adjacent code patterns** in the files being modified and follow the
   same import, logging, and error-wrapping style.
3. **Check for existing helpers** before creating new utilities so the change
   stays DRY.
4. **Verify interface contracts** so new code extends the current surface
   instead of creating a parallel one.
5. **Cross-check the plan checklist** so every file in the phase inventory is
   actually addressed.

After each file is modified:
- **Compile check:** run the relevant project compile/type-check command
- **Pattern verify:** confirm the new code matches adjacent conventions
- **Import check:** confirm no circular dependency or dead import was added

### `--tdd` Flag Behavior

When `--tdd` is active, Step 3 splits into sub-steps per phase:

```
Step 3.T: Write tests for CURRENT behavior (regression safety net)
Step 3.I: Implement changes (refactor, new code)
Step 3.V: Verify all tests from 3.T still pass + compile gates
```

Tests from Step 3.T document the current behavior. If any fail after Step 3.I,
the refactor broke something and must be fixed before the workflow proceeds.

**All modes:**
- Use `TaskUpdate` to mark tasks as `in_progress` immediately.
- Execute phase tasks sequentially (Step 3.1, 3.2, etc.)
- Use `ui-ux-designer` for frontend
- Use `ai-multimodal` for image assets
- Run type checking after each file

**Parallel mode:**
- Utilize all tools of Claude Tasks: `TaskCreate`, `TaskUpdate`, `TaskGet` and `TaskList`
- Launch multiple `fullstack-developer` agents
- When agents pick up a task, use `TaskUpdate` to assign task to agent and mark tasks as `in_progress` immediately.
- Respect file ownership boundaries (they may come from each phase's `touches`; see `../../adf-plan/references/plan-contract.md`)
- Wait for parallel group before next

**Output:** `✓ Step 3: Implemented [N] files - [X/Y] tasks complete`

### Step 3.S: Conditional Simplify (live-diff gated)

Recompute signals from the live worktree (no hook state):

```bash
totals=$(git diff --numstat HEAD --ignore-all-space)
loc=$(echo "$totals" | awk '{s+=$1+$2} END {print s+0}')
files=$(echo "$totals" | awk 'NF{c++} END {print c+0}')
maxFile=$(echo "$totals" | awk 'BEGIN{m=0} {if ($1>m) m=$1} END {print m+0}')
modified=$(git diff --name-only HEAD)
```

Read thresholds from `.claude/config/adf-config.json` (`simplify.threshold.{locDelta,fileCount,singleFileLoc}`),
defaulting to 400 / 8 / 200. If any threshold is breached, spawn the simplifier
scoped to the modified files:

```
Agent(subagent_type="code-simplifier", prompt="Simplify these files while preserving behavior exactly: [file-list]", description="Simplify recent edits")
```

After the subagent returns, log only — never re-run or block:
- `git diff --shortstat HEAD -- [file-list]` changed → "simplifier made scoped edits"
- unchanged → "simplifier ran clean"

Skip the step entirely when `ADF_SIMPLIFY_DISABLED=1` or
`.claude/config/adf-config.json` `simplify.gate.enabled` is `false`.

**Output:** `✓ Step 3.S: Simplify [ran|skipped] - [scoped changes|clean|under threshold]`

### [Review Gate 3] Post-Implementation (skip if auto mode)
- Present implementation summary (files changed, key changes)
- Use `AskUserQuestion` to ask: "Proceed to testing?" / "Request implementation changes" / "Abort"
- **Auto mode:** Skip this gate

## Step 4: Testing (skip if no-test mode)

**All modes (except no-test):**
- Write tests: happy path, edge cases, errors
- Small tasks: run the relevant tests yourself. Medium and large: spawn `tester`: `Agent(subagent_type="tester", prompt="Run test suite for <files>; report pass/fail with output", description="Run tests")`
- When the phase has `acceptance` commands, list them in your reply before you run them, then run them as that phase's done check. They are executable plan content: review them like code (see `../../adf-plan/references/plan-contract.md`)
- On failures: diagnose (spawn `debugger` for non-obvious causes) → fix → repeat
- Forbidden: fake mocks, commented-out tests, weakened assertions

**Output:** `✓ Step 4: Tests [X/X passed]`

### [Review Gate 4] Post-Testing (skip if auto mode)
- Present test results summary
- Use `AskUserQuestion` to ask: "Proceed to code review?" / "Request test fixes" / "Abort"
- **Auto mode:** Skip this gate

## Step 5: Code Review

**Small tasks:** review your own diff against checks (a)-(e) below.

**Medium and large tasks:** spawn `code-reviewer` with explicit (a-e) checks and scout/acceptance context:
  ```
  Agent(subagent_type="code-reviewer",
       prompt="Review changes against these checks: (a) every acceptance criterion met; (b) no regression to business logic in touchpoints/blast-radius from scout; (c) no breaking changes to public contracts (signatures, schemas, APIs, env vars) unless explicitly called out; (d) follows existing patterns from scout; (e) no new lint/type/build errors anywhere. CONTEXT — scout summary: <scout-summary>; acceptance criteria: <acceptance-criteria>. Return score (X/10), critical, warnings, suggestions, and explicitly flag any side effects to trigger HARD-GATE-NO-SIDE-EFFECTS.",
       description="Code review")
  ```

**Interactive/Parallel/Code/No-test:**
- Interactive cycle (max 3): see `review-cycle.md`
- Requires user approval

**Auto:**
- Auto-approve only if `review-decision.json` is `PASS`, artifact validator passes, and `risk-gate.autoStopRequired` is false
- Auto-fix critical (max 3 cycles)
- Escalate to user after 3 failed cycles

**Fast:**
- Simplified review, no fix loop
- User approves or aborts

**Output:** `✓ Step 5: Review [score]/10 - [Approved|Auto-approved]`

**Artifact gate:** Step 5 must write review artifacts from
`.claude/skills/_shared/references/workflow-artifacts.md` and run:

Use the "Running the gate" snippet from `.claude/skills/_shared/references/workflow-artifacts.md` with `--stage finalize --artifact-dir <artifact-dir>`.

For high-risk `--auto`, stop with AskUserQuestion before finalize/commit/ship unless `risk-gate.json` has `humanApproved: true`.

## Step 6: Finalize

Run each item only when its condition holds:
1. Plan files exist → activate `/project-management` for a full sync-back of [plan-path]: reconcile completed Claude Tasks with every `phase-XX-*.md`, backfill stale checkboxes across all phases, then update `plan.md` status/progress. Edit only the Status cell in the `plan.md` table and report any task that cannot be matched to a phase file.
2. User-visible behavior, setup, commands or architecture changed → `Agent(subagent_type="docs-manager", prompt="Update docs for: <change summary>", description="Update docs")`
3. Claude Tasks were created → `TaskUpdate` marks them complete after sync-back.
4. New env vars or API keys introduced → onboarding check.
5. Ask the user whether to commit. Only after they say yes: `Agent(subagent_type="git-manager", prompt="Stage and commit: <summary>", description="Commit")`. Never commit unasked.

**Auto mode:** continue to the next phase from **Step 3**; still ask before committing.
**Others:** ask the user before the next phase.

**Output:** `✓ Step 6: Finalized - [plan synced|no plan] - [docs updated|no doc impact] - [committed|commit declined|awaiting user]`

## Mode-Specific Flow Summary

Legend: `[R]` = Review Gate (human approval required)

```
interactive: 0 → 1 → [R] → 2 → [R] → 3 → [R] → 4 → [R] → 5(user) → 6
auto:        0 → 1 → 2 → 3 → 4 → 5(artifact-gated auto) → 6 → next phase (stops on high risk)
fast:        0 → skip → 2(fast) → [R] → 3 → [R] → 4 → [R] → 5(simple) → 6
parallel:    0 → 1? → [R] → 2(parallel) → [R] → 3(multi-agent) → [R] → 4 → [R] → 5(user) → 6
no-test:     0 → 1 → [R] → 2 → [R] → 3 → [R] → skip → 5(user) → 6
code:        0 → skip → skip → 3 → [R] → 4 → [R] → 5(user) → 6
```

**Key difference:** `auto` mode skips human review gates only for low-risk, artifact-validated work.

## Rules

- Skip a step only with a mode or task-size justification, and say which.
- Delegation scales with size: small tasks test and review inline; medium and large tasks use `tester` and `code-reviewer`; finalize subagents follow the Step 6 conditions.
- For medium and large tasks, `TaskCreate` one Claude Task per unchecked plan item (priority order, dependencies), `TaskUpdate` to `in_progress` on pickup and `completed` when done.
- All step outputs follow format: `✓ Step [N]: [status] - [metrics]`
