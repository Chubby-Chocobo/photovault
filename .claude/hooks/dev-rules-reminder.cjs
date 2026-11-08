#!/usr/bin/env node
/**
 * Development Rules Reminder - UserPromptSubmit Hook (Optimized)
 *
 * Injects context: session info, rules, modularization reminders, and Plan Context.
 * Static env info (Node, Python, OS) now comes from SessionStart env vars.
 *
 * Exit Codes:
 *   0 - Success (non-blocking, allows continuation)
 *
 * Core logic extracted to lib/context-builder.cjs for reuse.
 */

// Crash wrapper
try {
  const fs = require('fs');
  const { createHookTimer, logHookCrash } = require('./lib/hook-logger.cjs');

  // Import shared context building logic
  const {
    buildReminderContext,
    buildInjectionScopeKey,
    reserveInjectionScope,
    markRecentlyInjected,
    clearPendingInjection
  } = require('./lib/context-builder.cjs');
  const { isHookEnabled, getProjectRoot } = require('./lib/adf-config-utils.cjs');

  // Early exit if hook disabled in config
  if (!isHookEnabled('dev-rules-reminder')) {
    process.exit(0);
  }

// ═══════════════════════════════════════════════════════════════════════════
// MAIN EXECUTION
// ═══════════════════════════════════════════════════════════════════════════

async function main() {
  const timer = createHookTimer('dev-rules-reminder', { event: 'UserPromptSubmit' });
  let sessionId = null;
  let scopeKey = 'session';
  let reservedScope = false;

  try {
    const stdin = fs.readFileSync(0, 'utf-8').trim();
    if (!stdin) {
      timer.end({ status: 'skip', exit: 0, note: 'empty-input' });
      process.exit(0);
    }

    const payload = JSON.parse(stdin);
    sessionId = payload.session_id || process.env.ADF_SESSION_ID || null;

    // Base for absolute plan/report/docs paths: the project root (see getProjectRoot), so a `cd`
    // into a subfolder does not point Claude at <subfolder>/plans
    const baseDir = getProjectRoot(payload.cwd || process.cwd());
    scopeKey = buildInjectionScopeKey({ baseDir });

    const reservation = reserveInjectionScope(sessionId, scopeKey, payload.transcript_path || null);
    reservedScope = reservation.reserved;
    if (!reservation.shouldInject) {
      timer.end({ status: 'skip', exit: 0, note: 'recently-injected' });
      process.exit(0);
    }

    // Use shared context builder with baseDir for absolute paths
    const { content } = buildReminderContext({ sessionId, baseDir });

    console.log(content);
    markRecentlyInjected(sessionId, scopeKey);
    timer.end({ status: 'ok', exit: 0, note: 'context-injected' });
    process.exit(0);
  } catch (error) {
    if (reservedScope) {
      clearPendingInjection(sessionId, scopeKey);
    }
    console.error(`Dev rules hook error: ${error.message}`);
    logHookCrash('dev-rules-reminder', error, { event: 'UserPromptSubmit' });
    process.exit(0);
  }
  }

  main();
} catch (e) {
  try {
    const { logHookCrash } = require('./lib/hook-logger.cjs');
    logHookCrash('dev-rules-reminder', e, { event: 'UserPromptSubmit' });
  } catch (_) {}
  process.exit(0); // fail-open
}
