---
description: Where API and event contracts live, how they change, and how consumers pin them
---

# Contracts

A contract is the interface two components agree on: a protobuf package, an OpenAPI document, an event schema, a smart-contract ABI. This file is the project's policy for changing them. Edit it to match how the team really works.

## Where contracts live

Fill in one row per contract. The system map (`docs/architecture/system-map.json`) lists the same contracts; the repo of a contract comes from the workspace manifest or the map, never from this table.

| Contract | Kind | Location | Producer | Consumers | Pinned how |
|----------|------|----------|----------|-----------|------------|
|          |      |          |          |           |            |

## Rules

- **Contract first.** Change the contract, then the producer, then the consumers. Do not change behavior that the contract does not describe.
- **Generated code is never edited by hand.** Change the source contract and regenerate.
- **One owner per contract.** The producer owns it; consumers propose changes by pull request.

## Backward compatibility

- Prefer additive changes: new optional fields, new endpoints, new event types.
- Deprecate before removing. Keep a deprecated field or endpoint for at least one full release of every consumer.
- Never reuse a protobuf field number or a removed field name. Mark them `reserved`.
- Never change the meaning or type of an existing field. Add a new one instead.
- An event schema is compatible when old consumers can read new events and new consumers can read old events, unless the team agreed on one direction.

## Breaking-change checks

Run the check that matches the contract kind before opening the producer pull request, and in CI.

| Kind | Check |
|------|-------|
| protobuf | `buf breaking --against '<base repo or ref>'` |
| OpenAPI | `oasdiff breaking --fail-on ERR <base> <rev>` |
| event schema | the schema registry compatibility check, or the JSON Schema comparison the team uses |
| smart-contract ABI | compare the ABI files; a removed or changed function or event is breaking |

A breaking change needs a new contract version (new package, path or topic) and a migration plan for every consumer.

## Pinning

Consumers pin a contract repo to a tag or a commit, never to a branch.

- Git submodule: the commit recorded in the superproject is the pin.
- Cargo: `git = "<url>", tag = "<tag>"` or `rev = "<sha>"`. A `branch` is not a pin.
- npm: `<url>#<tag or sha>`. `#main`, `#master` and a missing ref are not pins.
- Never put credentials in a URL. Use an ssh remote or a credential helper.

Pins move on purpose: a consumer pull request bumps the pin and says why. Differing pins across consumers are allowed while a rollout is in progress, but each should have an owner and a date.

## Checking for drift

```bash
node .claude/skills/workspace/scripts/workspace.cjs drift
node .claude/skills/workspace/scripts/workspace.cjs drift --json
```

The report lists, per contract, the ref each consumer pins and whether it is the local checkout's HEAD. It reads local files only and never fetches, so a pin is compared with the local clone of the contract, which may be behind its remote.

### CI recipe

1. Give the job a read-only deploy key (or a CI credential helper) for every member repo.
2. Clone the members: `node .claude/skills/workspace/scripts/workspace.cjs bootstrap --yes`.
3. Fail the job on unpinned or differing pins: `node .claude/skills/workspace/scripts/workspace.cjs drift --fail-on unpinned,differs`.

Do not pass `--allow-missing` in CI. With `--fail-on`, a member that was not cloned also fails the job, so a missing key cannot pass silently.

## Change workflow

1. Plan the change with a scope that holds the contract and every consumer.
2. Open the producer pull request first: contract change, compatibility check output, version note.
3. After it merges, open one pull request per consumer that bumps the pin and adapts the code. Link them to each other and to the producer pull request.
4. Merge consumers in the order that keeps every environment working.
5. Remove deprecated parts only after the last consumer has moved.

## Review checklist

- [ ] The change is additive, or a new version of the contract is introduced.
- [ ] The breaking-change check passed, and its output is in the pull request.
- [ ] Every consumer is in the plan scope and has a pull request or a note saying why not.
- [ ] Pins reference a tag or a commit, not a branch.
- [ ] Generated code was regenerated, not edited.
- [ ] No credential appears in a URL, a lock file or a pull request description.
