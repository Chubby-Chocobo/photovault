#!/usr/bin/env node
/**
 * adf-mode.cjs - Switch ADF between strict (ask as configured) and auto (asks become allows,
 * denies stay), and show what each knob does right now.
 *
 *   node .claude/skills/adf-mode/scripts/adf-mode.cjs auto|strict|status [--cwd <dir>] [--json]
 *
 * `auto` writes `mode: "auto"` to .claude/config/adf-config.json and `permissions.defaultMode:
 * "bypassPermissions"` to .claude/settings.local.json, remembering a permission mode that was
 * already there under `modeRestore`. `strict` removes `mode` and puts the remembered permission
 * mode back (or removes bypassPermissions when nothing was remembered, and the file itself when
 * nothing else is in it). Nothing else in either file is touched, and a file that is not valid JSON
 * is left alone with an error. A new session
 * picks the permission mode up; the ADF hooks read the mode on every call.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { getProjectRoot, loadConfigFromPath } = require('../../../hooks/lib/adf-config-utils.cjs');
const { ENV_VAR, CONFIG_REL, getMode } = require('../../../hooks/lib/adf-mode.cjs');
const { getGitConfig, LEVELS, GIT_DEFAULTS } = require('../../../hooks/lib/git-flow-config.cjs');
const { mergeSettingsLocal, SETTINGS_REL } = require('../../../hooks/lib/settings-local-writer.cjs');

const BYPASS = 'bypassPermissions';
const USAGE = 'usage: adf-mode.cjs auto|strict|status [--cwd <dir>] [--json]';
const KEPT = ['permissions.deny rules', 'permissions.ask rules (destructive commands; Claude Code prompts for them in every mode)', 'force-push ban on main and release branches', 'commit secret scan (refused instead of asked in auto)'];
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function parseArgs(argv) {
  const opts = { command: null, cwd: process.cwd(), json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--json') opts.json = true;
    else if (a === '--cwd') { opts.cwd = argv[i + 1]; i += 1; }
    else if (!a.startsWith('-') && !opts.command) opts.command = a;
    else return { error: `unknown argument: ${a}` };
  }
  if (!opts.cwd || typeof opts.cwd !== 'string') return { error: '--cwd needs a directory' };
  if (!['auto', 'strict', 'status'].includes(opts.command)) return { error: USAGE };
  return opts;
}

/** The config object, `{}` when the file is absent; throws when it exists but is not a JSON object, so a broken file is never overwritten. */
function readConfig(root) {
  const file = path.join(root, CONFIG_REL);
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch (err) {
    if (err && err.code === 'ENOENT') return {};
    throw new Error(`${CONFIG_REL} cannot be read (${err.code || 'error'})`);
  }
  let parsed;
  try { parsed = JSON.parse(text); } catch { throw new Error(`${CONFIG_REL} is not valid JSON; fix it first`); }
  if (!isObject(parsed)) throw new Error(`${CONFIG_REL} is not a JSON object; fix it first`);
  return parsed;
}

function writeConfig(root, config) {
  const file = path.join(root, CONFIG_REL);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(config, null, 2)}\n`);
}

/** The permission mode in settings.local.json: null when absent or unset; throws when the file is not a JSON object. */
function permissionMode(root) {
  const file = path.join(root, SETTINGS_REL);
  if (!fs.existsSync(file)) return null;
  const settings = loadConfigFromPath(file);
  if (!isObject(settings)) throw new Error(`${SETTINGS_REL} is not a JSON object; fix it first`);
  const value = settings.permissions && settings.permissions.defaultMode;
  return typeof value === 'string' ? value : null;
}

/** Both files are checked before either is written, so a broken settings file never leaves the config half-switched. */
function applyBoth(root, changes, editConfig, patch) {
  const config = readConfig(root);
  const current = permissionMode(root);
  const settingsPatch = patch(current);
  if (settingsPatch) mergeSettingsLocal(root, settingsPatch, { dryRun: true });
  changes.push(editConfig(config, current));
  writeConfig(root, config);
  if (!settingsPatch) return;
  const r = mergeSettingsLocal(root, settingsPatch);
  changes.push(...r.diff.map((d) => `${SETTINGS_REL}: ${d}`));
  // A file this command emptied (auto created it, strict removed the only key) is not left behind
  if (r.written && Object.keys(JSON.parse(fs.readFileSync(r.file, 'utf8'))).length === 0) {
    fs.unlinkSync(r.file);
    changes.push(`${SETTINGS_REL}: removed (nothing left in it)`);
  }
}

function setAuto(root, changes) {
  applyBoth(root, changes, (config, current) => {
    config.mode = 'auto';
    if (current && current !== BYPASS) config.modeRestore = { permissionsDefaultMode: current };
    else delete config.modeRestore;
    return `${CONFIG_REL}: mode = auto${config.modeRestore ? ` (remembering permissions.defaultMode ${current})` : ''}`;
  }, () => ({ permissions: { defaultMode: BYPASS } }));
}

function setStrict(root, changes) {
  const config = readConfig(root);
  // A remembered bypassPermissions is never restored: strict must not be the path that turns prompts off
  const remembered = isObject(config.modeRestore) && typeof config.modeRestore.permissionsDefaultMode === 'string' && config.modeRestore.permissionsDefaultMode !== BYPASS
    ? config.modeRestore.permissionsDefaultMode : null;
  applyBoth(root, changes, (cfg) => {
    delete cfg.mode;
    delete cfg.modeRestore;
    return `${CONFIG_REL}: mode removed (strict is the default)`;
  }, (current) => (remembered ? { permissions: { defaultMode: remembered } } : current === BYPASS ? { permissions: { defaultMode: null } } : null));
}

/** Every knob with its configured and effective value. */
function status(root) {
  const config = readConfig(root);
  const mode = getMode(root, { root });
  const auto = mode.mode === 'auto';
  const hooks = isObject(config.hooks) ? config.hooks : {};
  const rawGit = isObject(config.git) ? config.git : {};
  const privacyOn = config.privacyBlock !== false && hooks['privacy-block'] !== false;
  return {
    root,
    mode: mode.mode,
    source: mode.source,
    envOverride: process.env[ENV_VAR] || null,
    knobs: {
      gitEnforcement: { configured: LEVELS.includes(rawGit.enforcement) ? rawGit.enforcement : GIT_DEFAULTS.enforcement, effective: getGitConfig(root).enforcement },
      privacyBlock: privacyOn ? (auto ? 'allows (deny rules still apply)' : 'asks') : 'disabled',
      askGate: hooks['ask-gate'] === false ? 'disabled' : auto ? 'refuses AskUserQuestion' : 'silent',
      permissionsDefaultMode: (() => { try { return permissionMode(root) || 'unset (Claude Code default)'; } catch { return `unreadable (${SETTINGS_REL} is not a JSON object)`; } })(),
      kept: KEPT,
    },
  };
}

function render(s) {
  return [
    `mode: ${s.mode} (from ${s.source}${s.envOverride ? `, ${ENV_VAR}=${s.envOverride}` : ''})`,
    `project: ${s.root}`,
    `  git.enforcement: ${s.knobs.gitEnforcement.configured} -> ${s.knobs.gitEnforcement.effective}`,
    `  privacy-block: ${s.knobs.privacyBlock}`,
    `  ask-gate: ${s.knobs.askGate}`,
    `  permissions.defaultMode (${SETTINGS_REL}): ${s.knobs.permissionsDefaultMode}`,
    `  unchanged in both modes: ${s.knobs.kept.join('; ')}`,
  ].join('\n');
}

function main(argv, out = (t) => process.stdout.write(`${t}\n`), err = (t) => process.stderr.write(`${t}\n`)) {
  const opts = parseArgs(argv);
  if (opts.error) { err(opts.error); return 2; }
  const root = getProjectRoot(path.resolve(opts.cwd));
  if (!fs.existsSync(path.join(root, '.claude'))) { err(`adf-mode: ${root} has no .claude/ directory; run it inside an ADF project`); return 1; }
  const changes = [];
  let s;
  try {
    if (opts.command === 'auto') setAuto(root, changes);
    else if (opts.command === 'strict') setStrict(root, changes);
    s = status(root);
  } catch (e) { err(`adf-mode: ${e.message}`); return 1; }
  if (opts.json) out(JSON.stringify({ ...s, changes }, null, 2));
  else {
    for (const c of changes) out(c);
    out(render(s));
    if (changes.length > 0) out('A new Claude Code session picks up the permission mode; the ADF hooks use the new mode at once.');
    if (s.envOverride && opts.command !== 'status') out(`Note: ${ENV_VAR}=${s.envOverride} overrides the file for this session.`);
  }
  return 0;
}

if (require.main === module) process.exit(main(process.argv.slice(2)));

module.exports = { main };
