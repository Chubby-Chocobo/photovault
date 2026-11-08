/**
 * drift-targets.cjs - Which directories the drift report reads, and which files its cache watches.
 *
 * Workspace: every cloned manifest member that is not a contract, plus component subpaths; members
 * that are not cloned are reported as missing. Monorepo: component paths from the map and the
 * services/apps directories the map does not list. File system checks only, no git.
 *
 * @module drift-targets
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { roleDirComponents, MANIFEST_FILE } = require('./repo-shape-detector.cjs');
const { memberPath, memberState } = require('./workspace-manifest.cjs');
const { mapPath } = require('./system-map.cjs');

const WATCHED = ['.gitmodules', 'Cargo.toml', 'package.json', '.git/HEAD', '.git/index'];

const absOf = (root, rel) => path.join(root, ...String(rel).split('/'));
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };

/** Why a manifest member is not read, from its file system state: absent, a symlink, or a directory without .git. */
const SKIP_REASONS = { missing: 'not cloned', symlink: 'not a plain clone (symlink)', 'not-a-repo': 'not a git repository' };

function workspaceTargets(root, map, manifest) {
  const comps = (map && map.components) || [];
  const contractPaths = new Set(((map && map.contracts) || []).map((c) => c.path));
  const entries = [];
  const missing = [];
  const cloned = new Set();
  const clonedNames = new Set();
  for (const m of manifest.members) {
    const abs = memberPath(root, m);
    const state = memberState(root, m, { git: false });
    if (state !== 'cloned') { missing.push({ name: m.name, path: m.path, reason: SKIP_REASONS[state] }); continue; }
    cloned.add(abs);
    clonedNames.add(m.name);
    if (contractPaths.has(m.path)) continue;
    const component = comps.find((c) => c.path === m.path) || null;
    entries.push({ rel: m.path, abs, name: component ? component.name : m.name, component });
  }
  const memberRels = new Set(manifest.members.map((m) => m.path));
  for (const c of comps) {
    if (memberRels.has(c.path) || !clonedNames.has(c.member) || !isDir(absOf(root, c.path))) continue;
    entries.push({ rel: c.path, abs: absOf(root, c.path), name: c.name, component: c });
  }
  const reasons = new Map(missing.map((m) => [m.name, m.reason]));
  const missingComponents = new Map(comps.filter((c) => reasons.has(c.member)).map((c) => [c.name, reasons.get(c.member)]));
  return { entries, missing, missingComponents, cloned };
}

function monorepoTargets(root, map) {
  const comps = (map && map.components) || [];
  const entries = comps.filter((c) => typeof c.path === 'string' && isDir(absOf(root, c.path)))
    .map((c) => ({ rel: c.path, abs: absOf(root, c.path), name: c.name, component: c }));
  const listed = new Set(entries.map((e) => e.rel));
  for (const rel of roleDirComponents(root)) {
    if (!listed.has(rel)) entries.push({ rel, abs: absOf(root, rel), name: path.posix.basename(rel), component: null });
  }
  return { entries, missing: [], missingComponents: new Map(), cloned: new Set(entries.map((e) => e.abs)) };
}

/**
 * @param {{ root: string, map?: object|null, manifest?: object|null }} args map is the joined map from loadSystemMap
 * @returns {{ entries: { rel: string, abs: string, name: string, component: object|null }[], missing: { name: string, path: string, reason: string }[], missingComponents: Map<string, string>, cloned: Set<string> }}
 */
function driftTargets({ root, map = null, manifest = null }) {
  return manifest ? workspaceTargets(root, map, manifest) : monorepoTargets(root, map);
}

/** Absolute files whose mtimes key the drift cache. */
function watchedFiles({ root, docsRel = 'docs', targets }) {
  const dirs = new Set([...targets.cloned, ...targets.entries.map((e) => e.abs)]);
  const files = [path.join(root, MANIFEST_FILE), mapPath(root, docsRel)];
  for (const dir of dirs) for (const rel of WATCHED) files.push(absOf(dir, rel));
  return files;
}

module.exports = { driftTargets, watchedFiles, absOf };
