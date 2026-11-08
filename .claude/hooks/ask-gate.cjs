#!/usr/bin/env node
/**
 * ask-gate.cjs - PreToolUse hook on AskUserQuestion. In auto mode (adf-mode.cjs) it refuses the
 * question and tells Claude to decide and record instead, so skills with confirmation gates run
 * end to end. In strict mode it does nothing. Fails open: any error lets the question through.
 */

'use strict';

const REASON = [
  'ADF auto mode: do not ask the user.',
  'Choose by the stated principles (the brief\'s, then the plan\'s, then the project\'s conventions), else pick the recommended option, or the first one when none is recommended; for a free-text question choose the smallest answer that keeps the work moving.',
  'State the choice and why in your reply, and under a "Decisions" heading in the active plan.md when a plan exists (topic, chosen, alternatives, why, review later; format in .claude/skills/adf-plan/references/plan-contract.md), then continue.',
  'Prompts come back with "node .claude/skills/adf-mode/scripts/adf-mode.cjs strict".',
].join(' ');

function main() {
  let payload;
  try { payload = JSON.parse(require('fs').readFileSync(0, 'utf8') || '{}'); } catch { return; }
  if (payload.tool_name !== 'AskUserQuestion') return;
  const { isHookEnabled } = require('./lib/adf-config-utils.cjs');
  if (!isHookEnabled('ask-gate')) return;
  const { isAuto } = require('./lib/adf-mode.cjs');
  if (!isAuto(payload.cwd || process.cwd())) return;
  console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: REASON } }));
}

try { main(); } catch { /* fail open */ }
