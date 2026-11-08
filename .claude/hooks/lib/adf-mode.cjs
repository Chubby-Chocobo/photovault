/**
 * adf-mode.cjs - The one switch between prompting and running unattended.
 *
 * `strict` (the default) keeps every ask. `auto` turns every ask into an allow and never weakens a
 * deny: `git.enforcement: ask` behaves as `off`, the privacy hook does not ask, `AskUserQuestion` is
 * refused with an instruction to decide and record, and Claude Code's own permission prompts are off
 * through `permissions.defaultMode` in settings.local.json (written by `/adf-mode`). Deny rules, the
 * force-push ban and the commit secret scan are the same in both modes.
 *
 * Resolution: ADF_MODE in the environment (one session) > `mode` in .claude/config/adf-config.json
 * > strict. Unknown values fall back to strict. The config is the launched project's: $CLAUDE_PROJECT_DIR
 * whenever Claude Code set it, whatever directory a hook's cwd points at, so a clone that ships
 * `mode: "auto"` cannot flip a session that was started elsewhere; without it, the nearest .claude/
 * above cwd. In a workspace the root decides, a member's own file does not. What stays in both modes:
 * permissions.deny and the explicit permissions.ask rules (Claude Code prompts for those in every
 * mode), the force-push ban, and the commit secret scan (refused, not asked, in auto).
 *
 * @module adf-mode
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { getProjectRoot } = require('./adf-config-utils.cjs');

const MODES = ['strict', 'auto'];
const DEFAULT_MODE = 'strict';
const ENV_VAR = 'ADF_MODE';
const CONFIG_REL = path.join('.claude', 'config', 'adf-config.json');

const valid = (value) => (typeof value === 'string' && MODES.includes(value.trim().toLowerCase()) ? value.trim().toLowerCase() : null);

function configuredMode(root) {
  try {
    return valid(JSON.parse(fs.readFileSync(path.join(root, CONFIG_REL), 'utf8')).mode);
  } catch { return null; }
}

const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };

/** The launched project when Claude Code named one, else the project around cwd. */
function modeRoot(cwd) {
  const launched = process.env.CLAUDE_PROJECT_DIR;
  if (launched && path.isAbsolute(launched) && isDir(launched)) return launched;
  return getProjectRoot(typeof cwd === 'string' && cwd ? cwd : process.cwd());
}

/**
 * @param {string} [cwd] Directory the hook runs in; only consulted when $CLAUDE_PROJECT_DIR is not set
 * @param {{ root?: string }} [opts] root: read this project's config instead (the adf-mode command's --cwd)
 * @returns {{ mode: 'strict'|'auto', source: 'env'|'config'|'default', root: string }}
 */
function getMode(cwd, { root = modeRoot(cwd) } = {}) {
  const fromEnv = valid(process.env[ENV_VAR]);
  if (fromEnv) return { mode: fromEnv, source: 'env', root };
  const fromConfig = configuredMode(root);
  if (fromConfig) return { mode: fromConfig, source: 'config', root };
  return { mode: DEFAULT_MODE, source: 'default', root };
}

const isAuto = (cwd) => getMode(cwd).mode === 'auto';

/** An `ask` level becomes `off` in auto; `off` and `deny` never change. */
function relaxLevel(level, cwd) {
  return level === 'ask' && isAuto(cwd) ? 'off' : level;
}

/** The one line a session prints in auto, so the state is never silent. */
function modeLine(cwd) {
  const { mode, source } = getMode(cwd);
  if (mode !== 'auto') return null;
  const from = source === 'env' ? ` from ${ENV_VAR}` : '';
  return `Mode: auto${from} (asks become allows, denies stay; decide and record instead of asking; "node .claude/skills/adf-mode/scripts/adf-mode.cjs strict" restores prompts)`;
}

module.exports = { ENV_VAR, CONFIG_REL, getMode, isAuto, relaxLevel, modeLine };
