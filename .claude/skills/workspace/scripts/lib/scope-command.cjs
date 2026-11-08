/**
 * scope-command.cjs - `workspace.cjs scope [--plan <dir>] [--paths a,b] [--write-settings | --clear-settings] [--yes]`
 *
 * Shows the scope a plan or a path list names, the contract consumers and producers it pulls in,
 * and the Claude Code settings that keep a session on it. Settings go to
 * .claude/settings.local.json only, and only after --yes: without it the exact diff is printed.
 * Every reader of scope ignores an entry it cannot use, so the command says why, by count only (the
 * entry itself is never printed): it exits 1 for an entry that is not a path, component name or
 * contract id (a sentence, say) and for entries past the 50th, and only reports a well-formed entry
 * that names nothing yet (a new service, a member not cloned), which is normal while planning.
 *
 * @module scope-command
 */

'use strict';

const path = require('path');
const { loadConfig, resolvePlanPath } = require('../../../../hooks/lib/adf-config-utils.cjs');
const { detectRepoShape } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { loadManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { loadSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { planDirInside } = require('../../../../hooks/lib/scope-members.cjs');
const { readPlanScope, filterScopeEntries, resolveScope, expandContracts, deriveSuggestions } = require('../../../../hooks/lib/plan-scope.cjs');
const { mergeSettingsLocal, SETTINGS_REL } = require('./settings-local-writer.cjs');
const { list, fail, usageError } = require('./workspace-util.cjs');

const entries = (n) => `${n} scope ${n === 1 ? 'entry' : 'entries'}`;
// Constant texts: nothing from the plan is ever echoed
const PROBLEMS = {
  invalid: (n) => `${entries(n)} ignored: not a path, component name or contract id; write scope as an inline list (scope: [services/order, contracts/proto])`,
  overCap: (n) => `${entries(n)} past the first 50 ignored; name a contract instead of listing each consumer`,
};
const missingText = (n) => `${entries(n)} ${n === 1 ? 'names' : 'name'} nothing that exists yet (a new path, or a member not cloned); left out until it exists`;
const problemsOf = (by) => Object.keys(PROBLEMS).filter((k) => by && by[k] > 0).map((k) => PROBLEMS[k](by[k]));
const MANAGED_KEYS_OFF = { worktree: { sparsePaths: null }, claudeMdExcludes: null, adfScope: null };

/** The project config, and the active (session) or suggested (branch) plan resolved from the project root like the hooks do. */
function projectPlan(root, { resolve }) {
  const previous = process.cwd();
  try {
    process.chdir(root);
    const config = loadConfig({ includeProject: false, includeAssertions: false, includeLocale: false });
    const resolvedPlan = resolve ? resolvePlanPath(process.env.ADF_SESSION_ID || null, config) : { path: null, resolvedBy: null };
    if (resolvedPlan.path && !path.isAbsolute(resolvedPlan.path)) resolvedPlan.path = path.resolve(root, resolvedPlan.path);
    return { config, resolvedPlan };
  } catch { return { config: null, resolvedPlan: { path: null, resolvedBy: null } }; } finally { process.chdir(previous); }
}

function render(r) {
  const lines = [];
  if (r.paths.length === 0) lines.push('No scope resolved. Pass --plan <dir> or --paths a,b, or work inside a component.');
  else {
    lines.push(`Scope (${r.source}${r.plan ? `, ${r.plan}` : ''}): ${r.paths.join(', ')}`);
    for (const e of r.expansion) lines.push(`  + ${e.path} (${e.reason})`);
  }
  lines.push(...problemsOf(r.droppedBy));
  if (r.droppedBy && r.droppedBy.missing > 0) lines.push(missingText(r.droppedBy.missing));
  const s = r.suggestions;
  if (r.paths.length > 0) {
    if (s.sparsePaths) lines.push(`worktree.sparsePaths: ${s.sparsePaths.join(', ')}`);
    if (s.claudeMdExcludes.length > 0) lines.push(`claudeMdExcludes: ${s.claudeMdExcludes.length} entries`);
    if (s.repos) lines.push(`Repos: ${s.repos.map((x) => `${x.name} (${x.state})`).join(', ')}`);
  }
  return lines;
}

function settingsStep(root, patch, yes) {
  const r = mergeSettingsLocal(root, patch, { dryRun: !yes });
  const note = !r.changed ? `${SETTINGS_REL} is already up to date.`
    : r.written ? `Wrote ${SETTINGS_REL}.` : `Nothing written. Review the diff, then add --yes.`;
  return { settings: { file: SETTINGS_REL, changed: r.changed, written: r.written, diff: r.diff }, lines: [SETTINGS_REL, ...r.diff, note] };
}

/** @returns {{ code: number, result: object, text: string }} */
function run({ root, docsRel, opts }) {
  const write = opts['write-settings'] === true;
  const clear = opts['clear-settings'] === true;
  if (write && clear) return usageError('use --write-settings or --clear-settings, not both');
  if (opts.plan !== undefined && opts.paths !== undefined) return usageError('use --plan or --paths, not both');
  const yes = opts.yes === true && opts['dry-run'] !== true;

  try {
    if (clear) {
      const step = settingsStep(root, MANAGED_KEYS_OFF, yes);
      return { code: 0, result: { ok: true, settings: step.settings }, text: step.lines.join('\n') };
    }

    const { manifest, errors } = loadManifest(root);
    if (errors.length > 0) return fail(errors);
    const { map } = loadSystemMap(root, docsRel, { manifest });
    const shape = detectRepoShape(root).type;
    const cwd = typeof opts.cwd === 'string' ? opts.cwd : process.cwd();

    const explicit = typeof opts.paths === 'string' || typeof opts.plan === 'string';
    const { config, resolvedPlan } = projectPlan(root, { resolve: !explicit });
    let scope;
    let plan = null;
    if (typeof opts.paths === 'string') {
      scope = { ...filterScopeEntries(list(opts.paths), { root, map }), source: 'paths' };
    } else if (typeof opts.plan === 'string') {
      const dir = planDirInside(root, opts.plan);
      if (!dir) return fail('--plan must be a folder inside the project that holds plan.md');
      scope = { ...filterScopeEntries(readPlanScope(dir), { root, map }), source: 'plan' };
      plan = path.basename(dir);
    } else {
      scope = resolveScope({ root, map, manifest, resolvedPlan, cwd });
      plan = scope.planDir ? path.basename(scope.planDir) : null;
    }

    const expansion = expandContracts(map, scope.paths);
    const suggestions = deriveSuggestions({ root, map, manifest, shapeType: shape, paths: scope.paths, docsRel, plansRel: (config && config.paths && config.paths.plans) || 'plans' });
    const problems = problemsOf(scope.droppedBy);
    const result = {
      ok: problems.length === 0, shape, source: scope.source, plan, paths: scope.paths, dropped: scope.dropped, droppedBy: scope.droppedBy,
      expansion, suggestions, ...(problems.length > 0 ? { errors: problems } : {}),
    };
    const lines = render(result);

    if (write) {
      if (problems.length > 0) return fail(problems.map((p) => `${p}; fix the scope before writing settings`), { dropped: scope.dropped, droppedBy: scope.droppedBy });
      if (scope.paths.length === 0) return fail('no scope to write; pass --plan or --paths', { dropped: scope.dropped });
      const patch = { claudeMdExcludes: suggestions.claudeMdExcludes.length > 0 ? suggestions.claudeMdExcludes : null, adfScope: { plan, paths: scope.paths } };
      if (suggestions.sparsePaths) patch.worktree = { sparsePaths: suggestions.sparsePaths };
      const step = settingsStep(root, patch, yes);
      result.settings = step.settings;
      lines.push('', ...step.lines);
    }
    return { code: result.ok ? 0 : 1, result, text: lines.join('\n') };
  } catch (e) {
    return fail(e && e.message ? e.message : 'scope failed');
  }
}

module.exports = { run };
