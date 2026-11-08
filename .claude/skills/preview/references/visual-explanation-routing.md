# Visual Explanation Routing

Use this file when a workflow asks for a visual explanation, diagram, slide deck,
diff review, or recap. Load `../SKILL.md` first for command syntax, then use this
file to choose the mode.

## Mode Selection

| Need | Preview mode |
|---|---|
| View an existing Markdown file or directory | `/preview <path>` |
| Explain a concept or code path | `/preview --explain <topic>` |
| Generate a focused architecture/data-flow diagram | `/preview --diagram <topic>` |
| Terminal-friendly diagram only | `/preview --ascii <topic>` |
| Self-contained HTML explanation | `/preview --html --explain <topic>` |
| Slide deck | `/preview --html --slides <topic>` |
| Visual diff review for a branch, PR, or commit | `/preview --html --diff [ref]` |
| Compare an implementation plan to code | `/preview --html --plan-review <plan>` |
| Recap recent project context | `/preview --html --recap [timeframe]` |

## Specialist Handoffs

- Mermaid syntax: load `/mermaidjs-v11`.
- Publish-grade SVG/PNG architecture diagrams: use `/tech-graph`.
- Generated images or multimodal analysis: use `/ai-multimodal`.
- UI/UX style selection for slides or high-polish HTML: use
  `/ui-ux-pro-max`.
- Documentation update after a durable visual: use `/docs update` and
  `../../docs/references/documentation-management.md`.

## Output Rules

- Prefer the active plan's `visuals/` folder when a plan exists.
- If no plan exists, save under `plans/visuals/`.
- For HTML output, always include the theme toggle required by
  `html-css-patterns.md`.
- For diagrams, render and inspect the output; syntax validity alone is not
  enough.
