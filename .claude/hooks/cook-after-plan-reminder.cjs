#!/usr/bin/env node
/**
 * Plan Subagent Hook - Next Step Reminder
 *
 * Registered as PostToolUse on `Agent`: when the Plan or ADF planner subagent returns, adds
 * context telling Claude to stop and ask the user which next step they want before implementing.
 * Also gives the full absolute plan path so new sessions (after /clear) can find it in worktrees.
 * (Plain stdout from a SubagentStop hook never reaches the parent session, so that event cannot
 * carry this reminder.)
 *
 * Exit Codes:
 *   0 - Success (non-blocking)
 */

// Crash wrapper
try {
  const fs = require('fs');
  const path = require('path');
  const { isHookEnabled, readSessionState } = require('./lib/adf-config-utils.cjs');

  // Early exit if hook disabled in config
  if (!isHookEnabled('cook-after-plan-reminder')) {
    process.exit(0);
  }

  async function main() {
  try {
    const stdin = fs.readFileSync(0, 'utf-8').trim();
    if (!stdin) process.exit(0);

    const payload = JSON.parse(stdin);
    const agentType = String(payload.tool_input?.subagent_type || '');
    if (!['Agent', 'Task'].includes(payload.tool_name) || !/^(?:planner|Plan)$/.test(agentType)) process.exit(0);
    // A background planner returns at launch (status async_launched), before any plan exists
    if (payload.tool_response?.status !== 'completed') process.exit(0);

    // Get active plan path from session state (the hook payload carries the session id)
    let planPath = null;
    const state = readSessionState(payload.session_id);
    if (state?.activePlan) {
      planPath = state.activePlan;
      // Ensure it's absolute
      if (!path.isAbsolute(planPath) && state.sessionOrigin) {
        planPath = path.resolve(state.sessionOrigin, planPath);
      }
    }

    const lines = ['Planning complete. Stop here and ask the user which next step they want: implement, validate, audit, revise, or end.'];
    if (planPath) {
      lines.push(`Optional implementation command after user approval: /cook ${path.join(planPath, 'plan.md')}`);
    } else {
      // Fallback when plan path unavailable
      lines.push('Optional implementation command after user approval: /cook {full-absolute-path-to-plan.md}');
    }
    lines.push('Add --auto only if the user explicitly asks for autonomous implementation.');

    console.log(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: lines.join('\n') }
    }));
    process.exit(0);
  } catch (error) {
    // Silent fail - non-blocking
    process.exit(0);
  }
  }

  main();
} catch (e) {
  // Minimal crash logging (zero deps — only Node builtins)
  try {
    const fs = require('fs');
    const p = require('path');
    const logDir = p.join(__dirname, '.logs');
    if (!fs.existsSync(logDir)) fs.mkdirSync(logDir, { recursive: true });
    fs.appendFileSync(p.join(logDir, 'hook-log.jsonl'),
      JSON.stringify({ ts: new Date().toISOString(), hook: p.basename(__filename, '.cjs'), status: 'crash', error: e.message }) + '\n');
  } catch (_) {}
  process.exit(0); // fail-open
}
