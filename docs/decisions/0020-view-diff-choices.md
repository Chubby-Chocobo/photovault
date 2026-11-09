# 0020 View diff: how shortcuts converge to the desired state

- **Status:** Accepted
- **Spec refs:** FR-100 to FR-103, FR-105, FR-106, §8.13
- **Review trigger:** when a view rule changes, or M0-3 shows a shortcut operation the diff does not model

## Context

Spec §8.13 says how a view converges, but not the state transitions for each shortcut state. `ViewDiff.operations(desired:current:)` (`Policies/ViewDiff.swift`) is pure.

## Decision

It compares desired shortcuts with recorded ones and returns trash, move and create operations, in that order. Each group is sorted by view, then asset key.

| Current state | Desired | Operation |
|---|---|---|
| none | wanted, target `done` | create |
| none | wanted, target not `done` | nothing yet (a shortcut needs its target id at creation) |
| `pending` or `trashed` | wanted, target `done` | create |
| `done`, `movePending` or `failed` | target id changed | trash the old one, then create |
| `done`, `movePending` or `failed` | parent folder changed | move |
| `userRemoved` or `trashPending` | any | nothing |
| `done`, `movePending`, `failed` or `pending` | not wanted | trash |
| `trashed` or `trashPending` | not wanted | nothing |

## Consequences

- A shortcut that the owner deleted (`userRemoved`) is never recreated by the diff. Only "Dựng lại view" resets it (FR-102).
- Trash is always scheduled before create for the same slot, so a target change never leaves two shortcuts for one asset in one view.
- The diff sets no order between views. `ViewExecutor` (engine) works through the list in the order `ViewDiff` returns, so trash and move run before create (spec §8.13: "Ưu tiên trash/move > tạo").
