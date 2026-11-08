# Skill Validation Checklist

Quick validation before packaging. Run `scripts/package_skill.py` for automated checks.

## Critical (Must Pass)

### Metadata
- [ ] `name`: namespaced `namespace:skill-name` (or `skill-name` for legacy), descriptive
- [ ] `description`: under 200 characters, specific triggers, not generic

### Size Limits
- [ ] SKILL.md: under 300 lines
- [ ] Each reference file: under 300 lines
- [ ] No info duplication between SKILL.md and references

### Structure
- [ ] SKILL.md exists with valid YAML frontmatter
- [ ] Unused example files deleted
- [ ] File names: kebab-case, self-documenting

## Scripts (If Applicable)

- [ ] Tests exist and pass
- [ ] Cross-platform (Node.js/Python preferred)
- [ ] Env vars: respects hierarchy `process.env` > `./.claude/skills/${SKILL}/.env` > `./.claude/skills/.env` > `./.claude/.env` > user-level `~/.claude/...` equivalents (see `.claude/scripts/resolve_env.py`)
- [ ] Dependencies documented (requirements.txt, .env.example)
- [ ] Manually tested with real use cases

## Quality

### Writing Style
- [ ] Imperative form: "To accomplish X, do Y"
- [ ] Third-person metadata: "This skill should be used when..."
- [ ] Concise, no fluff

### Practical Utility
- [ ] Teaches *how* to do tasks, not *what* tools are
- [ ] Based on real workflows
- [ ] Includes concrete trigger phrases/examples

## Integration

- [ ] No duplication with existing skills
- [ ] Related topics consolidated (e.g., cloudflare + docker → devops)
- [ ] Composable with other skills

## Automated Validation

Run packaging script to validate:

```bash
scripts/package_skill.py <path/to/skill-folder>
```

Checks performed:
- YAML frontmatter format
- Required fields present
- Description length (<200 chars)
- Directory structure
- File organization

Fix all errors before distributing.

## Subagent Delegation

Current Claude models follow instructions literally and over-apply shouted rules ("must", ""), and every subagent reloads project context. When a skill delegates:

1. **State the trigger and the reason** - when to delegate and why ("spawn `tester` for multi-file changes so test output stays out of the main context"), not just "must spawn".
2. **Scale by task size** - small changes run inline; reserve subagents for broad, parallel or high-risk work.
3. **Show the exact call** - `Agent(subagent_type="X", prompt="<task, files, acceptance criteria>", description="Z")`.
4. **Require real verification** - report done only after running the tests, type-check or build; never claim a check that was not run.

**Weak (no trigger, no reason):**
```
- Use `tester` agent for testing
```

**Better:**
```
- Medium or large changes: spawn `tester` with the changed files and acceptance criteria: `Agent(subagent_type="tester", prompt="Run tests for <files>; report pass/fail with output", description="Test")`. Small changes: run the relevant tests yourself.
```
