# Script Quality Criteria

Scripts provide deterministic reliability and token efficiency.

## When to Include Scripts

- Same code rewritten repeatedly
- Deterministic operations needed
- Complex transformations
- External tool integrations

## Cross-Platform Requirements

**Prefer:** Node.js or Python
**Avoid:** Bash scripts (not well-supported on Windows)

If bash required, provide Node.js/Python alternative.

## Testing Requirements

**Mandatory:** All scripts must have tests

```bash
# Run tests before packaging
python -m pytest scripts/tests/
# or
npm test
```

Tests must pass. No skipping failed tests.

## Environment Variables

Respect the hierarchy used by `.claude/scripts/resolve_env.py` (first found wins; project before user-level):

1. `process.env` (runtime)
2. `./.claude/skills/<skill-name>/.env` (project, skill-specific)
3. `./.claude/skills/.env` (project, shared skills)
4. `./.claude/.env` (project)
5. `~/.claude/skills/<skill-name>/.env` (user, optional)
6. `~/.claude/skills/.env` (user, optional)
7. `~/.claude/.env` (user, optional)

Prefer calling `.claude/scripts/resolve_env.py` over re-implementing this.

**Implementation pattern (Python):**

```python
from pathlib import Path
from dotenv import load_dotenv

# load_dotenv never overrides an existing value, so load highest priority first
skill_dir = Path(__file__).resolve().parent.parent  # .claude/skills/my-skill
for env_file in [
    skill_dir / '.env',
    skill_dir.parent / '.env',            # .claude/skills/.env
    skill_dir.parent.parent / '.env',     # .claude/.env
    Path.home() / '.claude/skills/my-skill/.env',
    Path.home() / '.claude/skills/.env',
    Path.home() / '.claude/.env',
]:
    load_dotenv(env_file)
```

## Documentation Requirements

### .env.example
Show required variables without values:

```
API_KEY=
DATABASE_URL=
DEBUG=false
```

### requirements.txt (Python)
Pin major versions:

```
requests>=2.28.0
python-dotenv>=1.0.0
```

### package.json (Node.js)
Include scripts:

```json
{
  "scripts": {
    "test": "jest"
  }
}
```

## Manual Testing

Before packaging, test with real use cases:

```bash
# Example: PDF rotation script
python scripts/rotate_pdf.py input.pdf 90 output.pdf
```

Verify output matches expectations.

## Error Handling

- Clear error messages
- Graceful failures
- No silent errors
- Exit codes: 0 success, non-zero failure
