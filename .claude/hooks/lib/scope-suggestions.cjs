/**
 * scope-suggestions.cjs - What a plan scope implies: contract consumers and producers to touch,
 * and the Claude Code settings that keep a session focused on the scope.
 *
 * Pure reads of the system map, the manifest and a few `stat` calls. No git, no writes.
 *
 * @module scope-suggestions
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { consumersOf } = require('./system-map.cjs');
const { memberState } = require('./workspace-manifest.cjs');

const within = (child, parent) => child === parent || child.startsWith(`${parent}/`);
const overlaps = (a, b) => within(a, b) || within(b, a);
const unique = (list) => [...new Set(list)];

function isDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}

function exists(p) {
  try { fs.statSync(p); return true; } catch { return false; }
}

/**
 * Consumers and producers of every contract whose path holds a scope path.
 * @param {object|null} map
 * @param {string[]} paths Scope paths (repo-relative, posix)
 * @returns {{ path: string, component: string, reason: string }[]} Components not already in the scope
 */
function expandContracts(map, paths) {
  const out = [];
  if (!map || !Array.isArray(paths) || paths.length === 0) return out;
  const add = (component, reason) => {
    if (typeof component.path !== 'string') return;
    if (paths.some((p) => overlaps(p, component.path)) || out.some((e) => e.path === component.path)) return;
    out.push({ path: component.path, component: component.name, reason });
  };
  for (const contract of map.contracts || []) {
    if (typeof contract.path !== 'string' || !paths.some((p) => within(p, contract.path))) continue;
    for (const c of consumersOf(map, contract.id)) add(c, `consumer of ${contract.id}`);
    for (const c of map.components || []) {
      if (Array.isArray(c.produces) && c.produces.includes(contract.id)) add(c, `producer of ${contract.id}`);
    }
  }
  return out;
}

/**
 * @param {{ root: string, map: object|null, manifest: object|null, shapeType: string, paths: string[], docsRel?: string, plansRel?: string }} args
 * @returns {{ sparsePaths: string[]|null, claudeMdExcludes: string[], repos: { name: string, path: string, state: string }[]|null }}
 *   sparsePaths: monorepo only (null in a workspace, whose members are separate repos).
 *   claudeMdExcludes: out-of-scope components, plus every member with its own ADF install.
 *   repos: workspace only, the members that overlap the scope and the workspace itself.
 */
function deriveSuggestions({ root, map, manifest, shapeType, paths, docsRel = 'docs', plansRel = 'plans' }) {
  const inScope = unique([...paths, ...expandContracts(map, paths).map((e) => e.path)]);

  const sparsePaths = shapeType === 'monorepo' && inScope.length > 0
    ? unique([...inScope, '.claude', docsRel, plansRel, ...['contracts', 'libs'].filter((d) => isDir(path.join(root, d)))])
    : null;

  const claudeMdExcludes = [];
  if (inScope.length > 0) {
    for (const c of (map && map.components) || []) {
      if (typeof c.path === 'string' && !inScope.some((p) => overlaps(p, c.path))) claudeMdExcludes.push(`**/${c.path}/CLAUDE.md`);
    }
  }
  for (const m of (manifest && manifest.members) || []) {
    if (exists(path.join(root, ...String(m.path).split('/'), '.claude', '.adf-manifest'))) claudeMdExcludes.push(`**/${m.path}/.claude/CLAUDE.md`);
  }

  const repos = manifest
    ? [
      ...manifest.members.filter((m) => inScope.some((p) => overlaps(p, m.path))).map((m) => ({ name: m.name, path: m.path, state: memberState(root, m) })),
      { name: '(workspace)', path: '.', state: 'workspace' },
    ]
    : null;

  return { sparsePaths, claudeMdExcludes: unique(claudeMdExcludes), repos };
}

module.exports = { expandContracts, deriveSuggestions };
