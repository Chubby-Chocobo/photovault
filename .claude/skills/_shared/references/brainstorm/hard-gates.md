# Brainstorm Hard Gates

Shared by `brainstorm-technical` and `brainstorm-features`. Gates apply to every session regardless of perceived simplicity.

## Gate 1: No Implementation Before Approval

Do not invoke any implementation skill, write any code, scaffold any project, or take any implementation action until a design has been presented and the user has approved it. The design can be brief for simple work, but you must present it and get approval. The only transition out of brainstorming is `/adf-plan` (or end session).

## Gate 2: Scout First

Before asking ANY clarifying question or proposing ANY approach, scan the codebase. No exceptions. Collect before the Discovery phase:

1. Project type, primary language(s), framework(s) from manifests (package.json, pyproject.toml, go.mod, Cargo.toml, etc.)
2. Existing modules/files relevant to the topic (use `scout` or Glob/Grep)
3. Patterns/conventions already used for similar features
4. Existing docs in `./docs/` and related plans in `./plans/`
5. Constraints discovered (tech stack lock-in, existing schemas, public APIs, naming conventions)

Why: questions asked without codebase context produce vague answers and wasted cycles. Scout first, then ask specific questions grounded in what exists.

After scouting, tell the user in 3-6 bullets: "Here's what I found in the codebase relevant to your request", then proceed to Discovery.

## Gate 3: Exact Requirements

Discovery questions must extract concrete requirements, not vague intent. Before proposing approaches, you must be able to answer each in one sentence:

1. **Expected output**: the artifact(s) the user expects (file, behavior, UI screen, API response shape, CLI command), concrete enough to verify later.
2. **Acceptance criteria**: how the user knows it is done correctly (behaviors, inputs/outputs, edge cases that must work).
3. **Scope boundary**: what is explicitly OUT of scope for this round.
4. **Non-negotiable constraints**: tech stack, file locations, naming, backward compatibility, deadlines.
5. **Touchpoints**: existing files/modules (from scout) this will interact with or modify.

If any item is still vague after one round of questions, ask another round. Do not proceed to design on hand-wavy answers ("make it better", "add some validation", "improve UX"); push for concrete examples, sample inputs/outputs, or a reference to mimic.

Ground `AskUserQuestion` options in what scout found (e.g. "Should the new endpoint live in `src/api/users.ts` (existing pattern) or a new `src/api/profile/` module?"). Never ask abstract questions when the codebase already constrains the answer.

## Gate 4: Scope Check

If the request covers 3+ independent concerns (e.g. "platform with chat, billing, analytics"), flag it immediately before deep questioning. Help decompose into sub-projects: pieces, relationships, build order. Each sub-project gets its own brainstorm, plan, implement cycle. Do not spend questions refining details of a project that needs decomposition first.

## Gate 5: Present Before Ask

Never call `AskUserQuestion` about approaches, trade-offs, or decisions the user has not seen in visible response text. Internal reasoning is invisible. First write the options, key trade-offs, and your recommendation (2-4 bullets per option), then call `AskUserQuestion` with option labels and descriptions that stand alone. Clarifying questions are exempt only when grounded in facts already shown (e.g. the scout summary).

## Anti-Rationalization

| Thought | Reality |
|---------|---------|
| "This is too simple to need a design" | Simple projects waste the most work on unexamined assumptions. |
| "I already know the solution" | Then writing it down takes 30 seconds. Do it. |
| "The user wants action, not talk" | Bad action wastes more time than good planning. |
| "Let me explore the code first" | Scouting is step one, but follow the process around it. |
| "I'll just prototype quickly" | Prototypes become production code. Design first. |
