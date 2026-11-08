/**
 * scope-members.cjs - Which workspace members a plan or a path list puts in scope.
 *
 * Shared by `workspace.cjs repos` and the worktree skill's create-scope/remove-scope, so both
 * read a plan's `scope` the same way. Nothing here writes or spawns.
 *
 * @module scope-members
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { memberForPath } = require('./workspace-manifest.cjs');
const { relativePosix, insideRoot } = require('./path-containment.cjs');
const { loadSystemMap } = require('./system-map.cjs');
const { readPlanScope, filterScopeEntries } = require('./plan-scope.cjs');

/** Plan folder named with --plan: a directory holding plan.md inside `root`, or null. */
function planDirInside(root, value) {
  if (typeof value !== 'string' || !value) return null;
  try {
    const real = fs.realpathSync(path.resolve(root, value));
    if (!insideRoot(relativePosix(fs.realpathSync(root), real))) return null;
    return fs.existsSync(path.join(real, 'plan.md')) ? real : null;
  } catch { return null; }
}

/**
 * Repo-relative scope paths: the plan's `scope` entries (paths, map component names or contract ids) or an
 * explicit list, filtered by the strict scope charset. Everything else is dropped and counted.
 * @param {string} root Workspace root
 * @param {{ planDir?: string, entries?: string[] }} source
 * @param {{ manifest?: object|null, docsRel?: string }} [ctx]
 * @returns {{ paths: string[], dropped: number }}
 */
function scopePaths(root, { planDir, entries }, { manifest = null, docsRel = 'docs' } = {}) {
  const { map } = loadSystemMap(root, docsRel, { manifest });
  return filterScopeEntries(planDir ? readPlanScope(planDir) : entries || [], { root, map });
}

/** Members whose tree contains at least one of the repo-relative `paths`, once each, in manifest order. */
function membersForPaths(root, manifest, paths) {
  const hit = new Set();
  for (const p of paths) {
    const member = memberForPath(root, manifest, path.join(root, ...String(p).split('/')));
    if (member) hit.add(member.name);
  }
  return manifest.members.filter((m) => hit.has(m.name));
}

module.exports = { planDirInside, scopePaths, membersForPaths };
