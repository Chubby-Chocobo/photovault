/**
 * workspace-util.cjs - Small helpers shared by the workspace commands.
 *
 * A command returns `{ code, result, text }`: the exit code, the object `--json` prints and the
 * text a person reads.
 *
 * @module workspace-util
 */

'use strict';

const { NAME_RE, validateOrg } = require('../../../../hooks/lib/workspace-manifest-validate.cjs');
const { safeText } = require('../../../../hooks/lib/system-map-validate.cjs');

const NEEDS_YES = 'nothing written: re-run with --yes after confirming the dry-run output';

/** Comma-separated flag value to a list of non-empty trimmed items. */
const list = (value) => (typeof value === 'string' ? value.split(',').map((s) => s.trim()).filter(Boolean) : []);

const jsonText = (value) => `${JSON.stringify(value, null, 2)}\n`;

/** A failed command: exit 1, the messages as text. */
function fail(errors, extra = {}) {
  const messages = Array.isArray(errors) ? errors : [errors];
  return { code: 1, result: { ok: false, errors: messages, ...extra }, text: messages.join('\n') };
}

/** A bad command line: exit 2. */
function usageError(message) {
  return { code: 2, result: { ok: false, errors: [message] }, text: message };
}

/**
 * A message when `--org`, `--client` or `--product` hold something the files would reject, else
 * null. The message never echoes the value. `forMap` applies the system-map string rules
 * (monorepo mode), otherwise the manifest name rule.
 */
function identityError(opts, { forMap = false } = {}) {
  for (const key of ['client', 'product']) {
    if (opts[key] === undefined) continue;
    const ok = forMap ? safeText(opts[key]) : NAME_RE.test(opts[key]);
    if (!ok) return forMap ? `--${key} must be plain text (letters, digits, space . _ / : @ -) without "--"` : `--${key} must match ${NAME_RE}`;
  }
  if (opts.org !== undefined) {
    const errors = validateOrg(list(opts.org), '--org');
    if (errors.length > 0) return errors[0];
  }
  return null;
}

/**
 * Gate for commands that write or clone: without `--yes` or `--dry-run` they only plan. The plan
 * comes back with exit 2 so a caller must confirm it first; a plan that already failed is returned as is.
 */
function needsYes(run) {
  return (ctx) => {
    if (ctx.opts.yes || ctx.opts['dry-run']) return run(ctx);
    const planned = run({ ...ctx, opts: { ...ctx.opts, 'dry-run': true } });
    if (planned.code !== 0) return planned;
    return { code: 2, result: { ok: false, needsYes: true, message: NEEDS_YES, planned: planned.result }, text: `${NEEDS_YES}\n\n${planned.text}` };
  };
}

module.exports = { list, jsonText, fail, usageError, identityError, needsYes };
