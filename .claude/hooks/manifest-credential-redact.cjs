#!/usr/bin/env node
/**
 * manifest-credential-redact.cjs - PostToolUse: hide credentials embedded in URLs before Claude sees them
 *
 * Matcher Read|Bash|Grep|Edit|MultiEdit. Walks every string leaf of tool_response and masks
 * `https://<token>@host` userinfo (plus npmrc/netrc/pypirc auth lines when the call names such a
 * file), then returns the whole response as hookSpecificOutput.updatedToolOutput. Bash is narrowed
 * to commands that name a manifest, lockfile, git config or a git remote subcommand.
 * Bash output saved to disk (persistedOutputPath) keeps the original, so that file is rewritten too.
 *
 * Fail-open: any error exits 0 without output. The original value is never printed or logged.
 * Toggle: hooks.manifest-credential-redact=false. A seatbelt, not the only control: deny/ask rules,
 * the commit guard and gitleaks stay in force.
 */

(async () => {
  try {
    const fs = require('fs');
    const os = require('os');
    const path = require('path');
    const { readTextCapped } = require('./lib/read-text-capped.cjs');
    const { redactText, redactLeaves, stringLength, shouldInspect, namesConfigFile } = require('./lib/manifest-credential-redactor.cjs');

    const HOOK = 'manifest-credential-redact';
    const TOOLS = new Set(['Read', 'Bash', 'Grep', 'Edit', 'MultiEdit']);
    const MAX_CHARS = 1024 * 1024;
    const MAX_PERSISTED_BYTES = 16 * 1024 * 1024;
    const CONTEXT = (n) => `${n} credential(s) were redacted. Replace them with a deploy key or a CI credential helper; do not ask the user to paste them.`;
    // Two payloads can hold a credential without `://` and `@`: a call naming .npmrc/.netrc/.pypirc (auth lines
    // carry no URL), and a Bash output saved to disk (the inline preview is only the first 30,000 characters)
    const CONFIG_FILE_NAME = /\.(?:npmrc|netrc|pypirc)\b/;

    // Cheap exit: any other payload with no `://` and `@` cannot hold a credential URL
    const mayHoldCredential = (raw) => (raw.includes('://') && raw.includes('@')) || CONFIG_FILE_NAME.test(raw) || raw.includes('"persistedOutputPath"');

    /**
     * Rewrites a saved Bash output file in place. Only a Bash `tool-results` file under the Claude config
     * dir's projects tree is touched (CLAUDE_CONFIG_DIR, else ~/.claude). The file is read and written as
     * latin1 so bytes that are not UTF-8 survive, and replaced atomically. Best-effort: any failure returns 0.
     */
    function redactPersisted(tool, file, opts) {
      try {
        if (tool !== 'Bash' || typeof file !== 'string' || !path.isAbsolute(file)) return 0;
        const base = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
        const root = fs.realpathSync(path.join(base, 'projects'));
        const real = fs.realpathSync(file);
        if (!real.startsWith(root + path.sep) || path.basename(path.dirname(real)) !== 'tool-results') return 0;
        const original = readTextCapped(real, MAX_PERSISTED_BYTES, { encoding: 'latin1' });
        if (original === null) return 0;
        const { text, count } = redactText(original, opts);
        if (count > 0) {
          const tmp = `${real}.${process.pid}.redact`;
          fs.writeFileSync(tmp, text, { encoding: 'latin1', mode: fs.statSync(real).mode & 0o777 });
          fs.renameSync(tmp, real);
        }
        return count;
      } catch {
        return 0;
      }
    }

    async function main() {
      process.stdin.setEncoding('utf8');
      let raw = '';
      for await (const chunk of process.stdin) raw += chunk;

      // The common case ends here with no logging and no config read; the heavier modules load only past it
      if (!mayHoldCredential(raw)) return;
      const { createHookTimer } = require('./lib/hook-logger.cjs');
      const { isHookEnabled } = require('./lib/adf-config-utils.cjs');
      const timer = createHookTimer(HOOK, { event: 'PostToolUse' });
      if (!isHookEnabled(HOOK)) {
        timer.end({ status: 'ok', exit: 0, note: 'disabled' });
        return;
      }

      let data;
      try {
        data = JSON.parse(raw);
      } catch {
        // The parser's message quotes part of the input, so only a fixed note is logged
        timer.end({ status: 'warn', exit: 0, note: 'json-parse-failed' });
        return;
      }

      const { tool_name: tool, tool_input: input, tool_response: response } = data || {};
      if (!TOOLS.has(tool) || response === undefined || response === null) {
        timer.end({ tool, status: 'ok', exit: 0, note: 'skipped' });
        return;
      }
      const cwd = typeof data.cwd === 'string' ? data.cwd : process.cwd();
      if (!shouldInspect(tool, input, cwd)) {
        timer.end({ tool, status: 'ok', exit: 0, note: 'not-inspected' });
        return;
      }
      if (stringLength(response) > MAX_CHARS) {
        timer.end({ tool, status: 'warn', exit: 0, note: 'too-large' });
        return;
      }

      const opts = { configLines: namesConfigFile(input) };
      const inline = redactLeaves(response, opts);
      const persisted = redactPersisted(tool, response.persistedOutputPath, opts);
      const total = inline.count + persisted;
      if (total === 0) {
        timer.end({ tool, status: 'ok', exit: 0, note: 'clean' });
        return;
      }

      const output = { hookEventName: 'PostToolUse', additionalContext: CONTEXT(total) };
      if (inline.count > 0) output.updatedToolOutput = inline.value;
      process.stdout.write(JSON.stringify({ hookSpecificOutput: output }));
      timer.end({ tool, status: 'ok', exit: 0, note: `redacted:${total}` });
    }

    // Run main only when executed directly (not when required for testing)
    if (require.main === module) {
      main().catch((error) => {
        try {
          require('./lib/hook-logger.cjs').logHookCrash('manifest-credential-redact', error, { event: 'PostToolUse' });
        } catch (_) { /* logging must never break the hook */ }
        process.exitCode = 0;
      });
    }
  } catch (e) {
    try {
      const { logHookCrash } = require('./lib/hook-logger.cjs');
      logHookCrash('manifest-credential-redact', e, { event: 'PostToolUse' });
    } catch (_) { /* logging must never break the hook */ }
    process.exitCode = 0; // fail-open
  }
})();
