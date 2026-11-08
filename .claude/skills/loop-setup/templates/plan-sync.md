<!-- adf-loop-template: plan-sync -->
Keep the active implementation plan in `plans/` in step with the code.

1. Find the active plan: the newest `plans/*/plan.md` whose status is not completed. None: say so
   in one line and stop the loop.
2. Compare its phase files with the commits and working-tree changes since the last iteration
   (`git log`, `git diff`). Nothing changed: say "plan <name>: no change" and wait longer next time.
3. Tick only the todo items that the code shows done and that a check you ran in this iteration
   confirms; never tick an item on intent. Update the phase status and the plan status table to match.
4. A phase looks done but its success criteria are unchecked: run the narrowest check, then report.
5. All phases complete: set the plan status to completed, summarize what shipped, and stop the loop.

Edit files under `plans/` only. Do not change code, commit, or push from this loop.
