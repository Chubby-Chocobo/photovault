---
name: coding-level
description: "Set coding experience level for tailored output. Use for adjusting explanation depth, code complexity, and response format to user expertise."
user-invocable: true
disable-model-invocation: true
when_to_use: "Invoke when response depth should match user expertise."
category: utilities
keywords: [experience, level, explanation, format]
argument-hint: "[0-5]"
metadata:
  author: adf
  version: "1.0.0"
---

# Coding Level

Set your coding experience level for tailored explanations and output format.

## Usage

`/coding-level [0-5]`

## Levels

| Level | Name | Description |
|-------|------|-------------|
| 0 | ELI5 | Zero coding experience - analogies, no jargon, step-by-step |
| 1 | Junior | 0-2 years - concepts explained, WHY not just HOW |
| 2 | Mid-Level | 3-5 years - design patterns, system thinking |
| 3 | Senior | 5-8 years - trade-offs, business context, architecture |
| 4 | Tech Lead | 8-10 years - risk assessment, business impact, strategy |
| 5 | God Mode | Expert - default behavior, maximum efficiency (default) |

## How It Works

Manual opt-in; nothing is injected at session start.

When invoked with a level:
1. Read `.claude/output-styles/coding-level-{N}-*.md` for that level
2. Follow its guidelines for the rest of the session
3. Tell the user they can make it persistent with `/output-style coding-level-{N}-<name>`

## Output Styles

| Level | `/output-style` value |
|-------|-----------------------|
| 0 | `coding-level-0-eli5` |
| 1 | `coding-level-1-junior` |
| 2 | `coding-level-2-mid` |
| 3 | `coding-level-3-senior` |
| 4 | `coding-level-4-lead` |
| 5 | `coding-level-5-god` |
