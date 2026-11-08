#!/usr/bin/env node
/**
 * Backend of the optional adf-mod Claude Code plugin (plugins/adf-mod in the ADF repo). A mod
 * has no Node.js APIs, so it runs this script to read ADF state with ADF's own helpers.
 *
 *   status [--session <id>]   JSON: project root, active unfinished plan with checkbox progress,
 *                             code files edited since the last check (verify-before-stop)
 *   plans                     unfinished plans under the plans directory, with progress
 *   statusline [mode]         print the statusline mode, or set it to full, compact, minimal or none
 *
 * Runs from the project directory; the project root is resolved like every ADF hook.
 */

const fs = require('node:fs');
const path = require('node:path');

const {
  getProjectRoot, loadConfig, resolvePlanPath, LOCAL_CONFIG_PATH,
} = require('../hooks/lib/adf-config-utils.cjs');
const { readState } = require('../hooks/verify-before-stop.cjs');
const { readPlan } = require('../skills/adf-brief/scripts/brief-scan.cjs');
const { scanPlanDirectory } = require('../skills/adf-brief/scripts/lib/checkboxes.cjs');

const STATUSLINE_MODES = ['full', 'compact', 'minimal', 'none'];

/** { title, dir, status, open, closed, total } for a plan directory, or null without plan.md. */
function planSummary(root, dir) {
  const planFile = path.join(dir, 'plan.md');
  let content;
  try { content = fs.readFileSync(planFile, 'utf8'); } catch { return null; }
  const rel = path.relative(root, planFile).split(path.sep).join('/');
  const plan = readPlan(content, rel, { type: 'filesystem' });
  const progress = scanPlanDirectory(dir, []) || { open: 0, closed: 0, total: 0 };
  return {
    title: plan.title,
    dir: path.dirname(rel),
    status: plan.status,
    unfinished: plan.unfinished,
    open: progress.open,
    closed: progress.closed,
    total: progress.total,
  };
}

function status(root, sessionId) {
  const config = loadConfig({ includeProject: false, includeAssertions: false, includeLocale: false });
  const { path: planPath } = resolvePlanPath(sessionId, config);
  const summary = planPath ? planSummary(root, path.resolve(root, planPath)) : null;
  const unverified = sessionId ? readState(sessionId).files || [] : [];
  // A completed or cancelled plan is not shown as active
  return { root, plan: summary && summary.unfinished ? summary : null, unverified };
}

function plans(root) {
  const config = loadConfig({ includeProject: false, includeAssertions: false, includeLocale: false });
  const plansDir = path.resolve(root, config.paths?.plans || 'plans');
  let entries = [];
  try { entries = fs.readdirSync(plansDir, { withFileTypes: true }); } catch { /* no plans directory */ }
  const found = entries
    .filter((e) => e.isDirectory() && e.name !== 'reports' && !e.name.startsWith('.'))
    .map((e) => planSummary(root, path.join(plansDir, e.name)))
    .filter((p) => p && p.unfinished)
    .sort((a, b) => b.dir.localeCompare(a.dir));
  if (!found.length) return ['No unfinished plans.'];
  return found.map((p) => {
    const progress = p.total ? `${p.closed}/${p.total}` : 'no todos';
    return `${p.dir}  ${p.status}  ${progress}  ${p.title}`;
  });
}

/** Print the statusline mode, or write it to the project's adf-config.json keeping every other key. */
function statusline(root, mode) {
  if (!mode) {
    const config = loadConfig();
    const base = config.statuslineLayout?.baseMode;
    return { code: 0, out: [`statusline: ${base || config.statusline}${base ? ' (from statuslineLayout.baseMode)' : ''}`] };
  }
  if (!STATUSLINE_MODES.includes(mode)) {
    return { code: 1, out: [`Unknown statusline mode "${mode}". Use ${STATUSLINE_MODES.join(', ')}.`] };
  }
  const file = path.join(root, LOCAL_CONFIG_PATH);
  let config = {};
  try {
    config = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') return { code: 1, out: [`Cannot read ${LOCAL_CONFIG_PATH}: ${error.message}. Nothing changed.`] };
  }
  if (!config || typeof config !== 'object' || Array.isArray(config)) {
    return { code: 1, out: [`${LOCAL_CONFIG_PATH} does not hold a JSON object. Nothing changed.`] };
  }
  config.statusline = mode;
  // A custom layout's baseMode wins over statusline, so say so instead of silently doing nothing
  const note = config.statuslineLayout?.baseMode ? ` (statuslineLayout.baseMode "${config.statuslineLayout.baseMode}" still takes precedence)` : '';
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(config, null, 2)}\n`);
  return { code: 0, out: [`statusline: ${mode}${note}. It applies on the next statusline refresh.`] };
}

function run(args) {
  // loadConfig and the branch lookup read the current directory, so the caller runs from the project
  const root = getProjectRoot();
  const [command, ...rest] = args;
  if (command === 'status') {
    const at = rest.indexOf('--session');
    return { code: 0, out: [JSON.stringify(status(root, at >= 0 ? rest[at + 1] : null))] };
  }
  if (command === 'plans') return { code: 0, out: plans(root) };
  if (command === 'statusline') return statusline(root, rest[0]);
  return { code: 1, out: [`Unknown command "${command || ''}". Use status [--session <id>], plans or statusline [mode].`] };
}

if (require.main === module) {
  const { code, out } = run(process.argv.slice(2));
  (code === 0 ? process.stdout : process.stderr).write(`${out.join('\n')}\n`);
  process.exit(code);
}

module.exports = { run };
