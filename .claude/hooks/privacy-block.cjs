#!/usr/bin/env node
/**
 * privacy-block.cjs - Ask the user before accessing sensitive files
 *
 * PRIVACY-based gating (separate from SIZE-based scout-block).
 * For any tool call touching a sensitive path, emits a PreToolUse
 * permissionDecision "ask" so Claude Code itself prompts the user.
 *
 * Core logic extracted to lib/privacy-checker.cjs for reuse.
 */

(async () => {
  try {
  const path = require('path');
  const { createHookTimer, logHookCrash } = require('./lib/hook-logger.cjs');

    // Import shared privacy checking logic
    const {
      checkPrivacy,
      isSafeFile,
      isPrivacyBlockDisabled,
      isPrivacySensitive,
      extractPaths
    } = require('./lib/privacy-checker.cjs');
    const { isHookEnabled } = require('./lib/adf-config-utils.cjs');

    // Early exit if hook disabled in config
    if (!isHookEnabled('privacy-block')) {
      process.exit(0);
    }

// Main
async function main() {
  const timer = createHookTimer('privacy-block', { event: 'PreToolUse' });
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk;
  }

  let hookData;
  try {
    hookData = JSON.parse(input);
  } catch (e) {
    timer.end({ status: 'warn', exit: 0, note: 'json-parse-failed', error: e.message });
    process.exit(0); // Invalid JSON, allow
  }

  const { tool_input: toolInput, tool_name: toolName } = hookData;

  const result = checkPrivacy({ toolName, toolInput, options: { cwd: hookData.cwd } });

  // Auto mode: the ask becomes an allow; the deny rules in permissions.deny still apply on their own
  if (result.sensitive && require('./lib/adf-mode.cjs').isAuto(hookData.cwd)) {
    timer.end({ tool: toolName, status: 'auto-allow', exit: 0, target: path.basename(result.filePath || ''), note: 'auto-mode' });
    process.exit(0);
  }

  if (result.sensitive) {
    // Claude Code prompts the user natively; the model cannot self-approve
    console.log(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'ask',
        permissionDecisionReason: result.reason
      }
    }));
    timer.end({
      tool: toolName,
      status: 'ask',
      exit: 0,
      target: path.basename(result.filePath || ''),
      note: 'approval-required'
    });
    process.exit(0);
  }

  timer.end({ tool: toolName, status: 'ok', exit: 0 });
  process.exit(0); // Allow
}

    // Run main only when executed directly (not when required for testing)
    if (require.main === module) {
      main().catch((error) => {
        logHookCrash('privacy-block', error, { event: 'PreToolUse' });
        process.exit(0);
      });
    }

    // Export functions for unit testing
    if (typeof module !== 'undefined') {
      module.exports = {
        isSafeFile,
        isPrivacyBlockDisabled,
        isPrivacySensitive,
        extractPaths,
      };
    }
} catch (e) {
  try {
    const { logHookCrash } = require('./lib/hook-logger.cjs');
    logHookCrash('privacy-block', e, { event: 'PreToolUse' });
    } catch (_) {}
    process.exit(0); // fail-open
  }
})();
