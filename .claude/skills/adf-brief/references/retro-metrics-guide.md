# Metrics Reference Guide

Each metric: what it measures, why it matters and how to read it. `brief-scan.cjs --retro` computes every value; use this guide to interpret them, not to recompute them.

---

## Velocity Metrics

### Commits Per Day

**Measures:** Delivery cadence — how often work lands in the repo.
**Why it matters:** Low frequency may indicate large batched PRs (risky merges); high frequency with tiny commits suggests good trunk-based dev hygiene.
**Interpretation:**
- `< 1/day` — infrequent; check for blocked PRs or slow review cycles
- `1-3/day` — healthy for a solo dev or small team
- `> 5/day` — high activity; verify commits are meaningful, not noise

### Active Day Ratio

**Measures:** What fraction of working days had at least one commit.
**Why it matters:** Consistent daily progress vs burst-then-idle patterns.
**Interpretation:** `> 70%` = consistent; `< 40%` = batchy; investigate blockers.

---

## Code Health Metrics

### LOC Added / Removed / Net

**Measures:** Raw volume of code written and deleted.
**Why it matters:** Net negative LOC (more deleted than added) is often a sign of healthy refactoring. Very high churn on specific files is a risk signal.
**Interpretation:**
- Net negative on non-test files = good (simplification)
- Net positive > 500 LOC/day sustained = high velocity, watch for quality regression

### File Hotspots

**Measures:** Which files change most frequently.
**Why it matters:** High-churn files are coupling magnets and defect attractors. Files appearing in > 30% of commits warrant refactoring.
**Interpretation:** Top 3 hotspots in every sprint signal architectural debt.

### Churn Rate

**Measures:** `(LOC_added + LOC_removed) / max(|LOC_net|, 1)`: how much code was rewritten vs kept.
**Why it matters:** Churn > 3x net LOC = significant rework; investigate root cause (unclear requirements, unstable APIs, poor initial design).
**Interpretation:**
- `1.0 - 1.5` = clean, additive work
- `1.5 - 3.0` = moderate iteration (normal)
- `> 3.0` = high rework; flag for retro discussion

---

## Quality Metrics

### Test-to-Code Ratio

**Measures:** `test_file_changes / total_file_changes * 100`. A test file is under `test/`, `tests/` or `__tests__/`, or is named `*.test.*`, `*.spec.*`, `test_*` or `*_test.*`.
**Why it matters:** Proxy for whether tests accompany new code. Does not measure test quality, only presence.
**Interpretation:**
- `> 30%` = tests accompanying changes (healthy)
- `10-30%` = some test coverage added
- `< 10%` = tests lagging behind; technical debt accumulating

### Commit Type Distribution

**Measures:** Breakdown of conventional commit types (`feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `hotfix`).
**Why it matters:** Ratio reveals focus. Heavy `fix` ratio may indicate quality issues; heavy `chore` may mean infra debt; balanced mix = sustainable pace.
**Interpretation:**
- `feat > 40%` = feature-driven sprint
- `fix > 40%` = reactive sprint (bugs dominating)
- `refactor > 20%` = healthy investment in code quality

---

## Plan Metrics

### Plan Completion Rate

**Measures:** the current checkbox completion (`- [x]` vs `- [ ]`) of the plan directories that commits in the period touched; with `--issues`, GitHub issues opened and closed in the period.
**Caveat:** the checkbox state is a snapshot taken now, so a plan started long ago and finished this week looks the same as one done entirely this week. Read it as "how far along the plans we worked on are", not as delivery in the period.
**Why it matters:** Tracks delivery predictability. Consistent undercompletion signals scope inflation or estimation issues.
**Interpretation:**
- `> 80%` = on track
- `60-80%` = acceptable; review blockers
- `< 60%` = scope or capacity mismatch; action needed
