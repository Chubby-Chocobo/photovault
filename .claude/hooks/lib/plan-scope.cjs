/**
 * plan-scope.cjs - Which paths a session or plan works on, in a monorepo or workspace.
 *
 * Order, first hit wins and never blocks: the active plan's `scope`, the suggested plan's
 * `scope`, the component containing cwd, then the branch name of the repo containing cwd. Plan
 * text can arrive by push, so every entry passes a strict filter; what fails it is counted and
 * never kept or printed. No git spawn: the branch is read from `.git/HEAD`.
 *
 * @module plan-scope
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { parseFrontmatter, toList } = require('./front-matter.cjs');
const { componentForPath } = require('./system-map.cjs');
const { memberForPath, memberPath } = require('./workspace-manifest.cjs');
const { expandContracts, deriveSuggestions } = require('./scope-suggestions.cjs');
const { realpathLoose, relativePosix, insideRoot } = require('./path-containment.cjs');

const ENTRY_RE = /^[A-Za-z0-9][A-Za-z0-9._/@-]{0,200}$/;
const MAX_ENTRIES = 50;
const MAX_READ_BYTES = 32 * 1024;
const BRANCH_PREFIX = /^(feat|fix|chore|refactor|docs|hotfix|release)\//;

function readHead(file, bytes) {
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.alloc(bytes);
    return buf.toString('utf8', 0, fs.readSync(fd, buf, 0, bytes, 0));
  } finally { fs.closeSync(fd); }
}

/**
 * Raw `scope` entries of <planDir>/plan.md: an inline list `[a, b]`, a block list, or one
 * comma-separated value. Nothing is validated here.
 * @returns {string[]}
 */
function readPlanScope(planDir) {
  let raw;
  try { raw = parseFrontmatter(readHead(path.join(planDir, 'plan.md'), MAX_READ_BYTES)).scope; } catch { return []; }
  return toList(raw);
}

/**
 * Repo-relative posix path for one entry, or why it has none: `invalid` (not a safe path or name,
 * such as a sentence, or a path leaving the root) or `missing` (well formed, but no such path,
 * component or contract yet).
 * @returns {{ path: string }|{ reason: 'invalid'|'missing' }}
 */
function entryPath(entry, realRoot, byName) {
  if (typeof entry !== 'string' || !ENTRY_RE.test(entry)) return { reason: 'invalid' };
  const cleaned = entry.replace(/\/+$/, '');
  if (cleaned.split('/').some((seg) => seg === '' || seg === '.' || seg === '..')) return { reason: 'invalid' };
  const abs = path.join(realRoot, ...cleaned.split('/'));
  if (fs.existsSync(abs)) return insideRoot(relativePosix(realRoot, realpathLoose(abs))) ? { path: cleaned } : { reason: 'invalid' };
  const component = byName.get(cleaned);
  return component && typeof component.path === 'string' ? { path: component.path } : { reason: 'missing' };
}

/**
 * @param {unknown[]} entries Raw entries from readPlanScope
 * @param {{ root: string, map?: object|null }} ctx
 * @returns {{ paths: string[], dropped: number, droppedBy: { invalid: number, missing: number, overCap: number } }}
 *   paths are repo-relative and unique; dropped counts what failed, droppedBy splits it by cause
 */
function filterScopeEntries(entries, { root, map }) {
  const list = Array.isArray(entries) ? entries : [];
  const realRoot = realpathLoose(root);
  // A contract id resolves to the contract's directory; a component of the same name wins
  const byName = new Map([...((map && map.contracts) || []).map((c) => [c.id, c]), ...((map && map.components) || []).map((c) => [c.name, c])]);
  const paths = new Set();
  const droppedBy = { invalid: 0, missing: 0, overCap: Math.max(0, list.length - MAX_ENTRIES) };
  for (const entry of list.slice(0, MAX_ENTRIES)) {
    const r = entryPath(entry, realRoot, byName);
    if (r.path) paths.add(r.path); else droppedBy[r.reason] += 1;
  }
  return { paths: [...paths], dropped: droppedBy.invalid + droppedBy.missing + droppedBy.overCap, droppedBy };
}

/**
 * Branch of the repo at `dir` from its HEAD file, following a `gitdir:` pointer file.
 * @returns {string|null} null for a detached HEAD or when nothing can be read
 */
function readBranchFromGitDir(dir) {
  try {
    const dotGit = path.join(dir, '.git');
    let gitDir = dotGit;
    if (fs.statSync(dotGit).isFile()) {
      const pointer = /^gitdir:\s*(.+?)\s*$/m.exec(readHead(dotGit, 1024));
      if (!pointer) return null;
      gitDir = path.resolve(dir, pointer[1]);
    }
    const ref = /^ref:\s*refs\/heads\/(.+?)\s*$/m.exec(readHead(path.join(gitDir, 'HEAD'), 1024));
    return ref ? ref[1] : null;
  } catch { return null; }
}

/** The one component whose name appears in the branch as whole "-" segments, else null. */
function componentFromBranch(branch, components) {
  const segments = branch.replace(BRANCH_PREFIX, '').toLowerCase().split(/[-/]/);
  const hits = [];
  for (const c of components) {
    const parts = String(c.name).toLowerCase().split('-');
    for (let i = 0; i + parts.length <= segments.length; i += 1) {
      if (parts.every((part, j) => segments[i + j] === part)) { hits.push({ c, start: i, end: i + parts.length }); break; }
    }
  }
  // admin-web inside admin-web-login also contains web: the longer name wins
  const kept = hits.filter((h) => !hits.some((o) => o !== h && o.start <= h.start && o.end >= h.end && o.end - o.start > h.end - h.start));
  return kept.length === 1 ? kept[0].c : null;
}

function planDirOf(resolvedPlan, root) {
  if (!resolvedPlan || typeof resolvedPlan.path !== 'string' || !resolvedPlan.path) return null;
  const candidates = path.isAbsolute(resolvedPlan.path) ? [resolvedPlan.path] : [path.resolve(process.cwd(), resolvedPlan.path), path.resolve(root, resolvedPlan.path)];
  return candidates.find((p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } }) || null;
}

/** Components of the repo that holds cwd: all of a monorepo's, one member's in a workspace, none at the workspace root. */
function branchScope({ root, map, manifest, cwd }) {
  let repoDir = root;
  let components = map.components || [];
  if (manifest) {
    const member = memberForPath(root, manifest, cwd);
    if (!member) return null;
    repoDir = memberPath(root, member);
    components = components.filter((c) => typeof c.path === 'string' && (c.path === member.path || c.path.startsWith(`${member.path}/`)));
  }
  const branch = readBranchFromGitDir(repoDir);
  const component = branch && componentFromBranch(branch, components);
  return component && typeof component.path === 'string' ? [component.path] : null;
}

/**
 * @param {{ root: string, map: object|null, manifest?: object|null, resolvedPlan?: { path: string|null, resolvedBy: 'session'|'branch'|null }, cwd?: string }} args
 * @returns {{ paths: string[], source: 'plan'|'suggested plan'|'cwd'|'branch'|null, dropped: number, droppedBy: object, planDir: string|null }}
 *   planDir is set only when the scope came from a plan; dropped (split by cause in droppedBy) counts plan entries that failed the filter.
 */
function resolveScope({ root, map, manifest = null, resolvedPlan, cwd = process.cwd() }) {
  let dropped = 0;
  let droppedBy = { invalid: 0, missing: 0, overCap: 0 };
  const planDir = planDirOf(resolvedPlan, root);
  if (planDir) {
    const entries = readPlanScope(planDir);
    const filtered = filterScopeEntries(entries, { root, map });
    ({ dropped, droppedBy } = filtered);
    if (filtered.paths.length > 0) {
      return { paths: filtered.paths, source: resolvedPlan.resolvedBy === 'session' ? 'plan' : 'suggested plan', dropped, droppedBy, planDir };
    }
  }
  const none = { paths: [], source: null, dropped, droppedBy, planDir: null };
  if (!map) return none;
  const rel = relativePosix(realpathLoose(root), realpathLoose(cwd));
  if (rel !== '' && !insideRoot(rel)) return none;
  const here = rel === '' ? null : componentForPath(map, rel);
  if (here && typeof here.path === 'string') return { ...none, paths: [here.path], source: 'cwd' };
  const byBranch = branchScope({ root, map, manifest, cwd });
  return byBranch ? { ...none, paths: byBranch, source: 'branch' } : none;
}

module.exports = {
  readPlanScope,
  filterScopeEntries,
  readBranchFromGitDir,
  componentFromBranch,
  resolveScope,
  expandContracts,
  deriveSuggestions,
};
