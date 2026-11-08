---
name: journal
description: "Record a setback or hard decision with its cause and lesson. Use only when the user asks or the work hit a real setback."
user-invocable: true
when_to_use: "Invoke when the user asks, or after a real setback or hard decision worth recording."
category: utilities
keywords: [journal, setback, decision, lesson]
argument-hint: "[topic or reflection]"
metadata:
  author: adf
  version: "1.0.0"
---

# Journal

One purpose: record a setback or hard decision with its cause and the lesson. Write only when the user asks or the work hit a real setback; routine completions need no entry.

Use the `journal-writer` subagent to explore the memories and recent code changes, and write the entry.
Keep entries concise: what happened, why, the decision, the lesson.
Keep journal entries in the `./plans/journals/` directory.

Invoke "/project-organization" skill to organize the outputs.

## Workflow Position

**Typically follows:** `/cook`, `/fix` or `/ship` that hit a notable setback, or any time the user asks
**Terminal skill** — no typical successor.
