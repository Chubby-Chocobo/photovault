# Parallel Exploration

Patterns for launching multiple subagents in parallel to scout codebase, verify implementation, and coordinate via native Tasks.

## Parallel Exploration (Scouting)

Launch multiple `Explore` subagents simultaneously when needing to find:
- Related files across different areas
- Similar implementations/patterns
- Dependencies and usage

**Pattern:**
```
Agent(subagent_type="Explore", prompt="Find [X] in [area1]", description="Scout area1")
Agent(subagent_type="Explore", prompt="Find [Y] in [area2]", description="Scout area2")
Agent(subagent_type="Explore", prompt="Find [Z] in [area3]", description="Scout area3")
```

**Example - Multi-area scouting:**
```
// Launch in SINGLE message with multiple Task calls:
Agent("Explore", "Find auth-related files in src/", "Scout auth")
Agent("Explore", "Find API routes handling users", "Scout API")
Agent("Explore", "Find test files for auth module", "Scout tests")
```

## Parallel Verification (Bash)

Launch multiple `Bash` subagents to verify implementation from different angles.

**Pattern:**
```
Agent(subagent_type="Bash", prompt="Run [command1]", description="Verify X")
Agent(subagent_type="Bash", prompt="Run [command2]", description="Verify Y")
```

**Example - Multi-verification:**
```
// Launch in SINGLE message:
Agent("Bash", "Run typecheck: bun run typecheck", "Verify types")
Agent("Bash", "Run lint: bun run lint", "Verify lint")
Agent("Bash", "Run build: bun run build", "Verify build")
```

## Task-Coordinated Parallel (Moderate+)

For multi-phase fixes, use native Tasks to coordinate parallel agents.
See `references/task-orchestration.md` for full patterns.

**Pattern - Parallel issue trees:**
```
// Create separate task trees per independent issue
T_A1 = TaskCreate(subject="[Issue A] Debug", activeForm="Debugging A")
T_A2 = TaskCreate(subject="[Issue A] Fix",   activeForm="Fixing A",   addBlockedBy=[T_A1])
T_B1 = TaskCreate(subject="[Issue B] Debug", activeForm="Debugging B")
T_B2 = TaskCreate(subject="[Issue B] Fix",   activeForm="Fixing B",   addBlockedBy=[T_B1])
T_final = TaskCreate(subject="Integration verify", addBlockedBy=[T_A2, T_B2])

// Spawn agents per issue tree
Agent("fullstack-developer", "Fix Issue A. Claim tasks via TaskUpdate.", "Fix A")
Agent("fullstack-developer", "Fix Issue B. Claim tasks via TaskUpdate.", "Fix B")
```

Agents claim work via `TaskUpdate(status="in_progress")` and complete via `TaskUpdate(status="completed")`. Blocked tasks auto-unblock when dependencies resolve.

## When to Use Parallel

| Scenario | Parallel Strategy |
|----------|-------------------|
| Root cause unclear, multiple suspects | 2-3 Explore agents on different areas |
| Multi-module fix | Explore each module in parallel |
| After implementation | Bash agents for typecheck + lint + build |
| Before commit | Bash agents for test + build + lint |
| 2+ independent issues | Task trees per issue + fullstack-developer agents |

## Combining Explore + Tasks + Bash

**Step 1:** Parallel Explore to scout
**Step 2:** Sequential implementation (update Tasks as phases complete)
**Step 3:** Parallel Bash to verify

```
// Scout phase - parallel
Agent("Explore", "Find payment handlers", "Scout payments")
Agent("Explore", "Find order processors", "Scout orders")

// Wait for results, implement fix, TaskUpdate each phase

// Verify phase - parallel
Agent("Bash", "Run tests: bun test", "Run tests")
Agent("Bash", "Run typecheck", "Check types")
Agent("Bash", "Run build", "Verify build")
```

## Resource Limits

- Max 3 parallel agents recommended (system resources)
- Each subagent has 200K token context limit
- Keep prompts concise to avoid context bloat
- Use `TaskList()` to check for available unblocked work
